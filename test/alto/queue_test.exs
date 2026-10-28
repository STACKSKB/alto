defmodule Alto.QueueTest do
  @moduledoc """
  Durable claim/ack queue coverage: put/claim/ack lifecycle, key dedup
  semantics (pending update, claimed conflict, blanked re-queue), leases
  and crash recovery across restart, cancellation, bounds, and loud
  corruption — the integration contract "durable queue" contract.
  """

  use ExUnit.Case, async: true

  alias Alto.Queue

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    %{dir: dir, id: unique_id()}
  end

  defp unique_id, do: "q" <> Integer.to_string(System.unique_integer([:positive]))

  defp start_queue!(opts) do
    name = :"queue_#{System.unique_integer([:positive])}"
    {:ok, pid} = Queue.start_link(Keyword.put(opts, :name, name))
    %{pid: pid, name: name}
  end

  test "a second owner of the same log is refused while the first is alive", %{dir: dir, id: id} do
    %{pid: pid} = start_queue!(id: id, dir: dir)

    assert {:error, :timeout} =
             Queue.start_link(
               id: id,
               dir: dir,
               name: String.to_atom("queue_other_#{System.unique_integer([:positive])}"),
               lock_timeout: 50
             )

    GenServer.stop(pid)
  end

  test "rejects an append that would exceed the configured log byte bound", %{dir: dir, id: id} do
    %{name: name} = start_queue!(id: id, dir: dir, max_log_bytes: 100)

    assert {:error, {:log_too_large, projected, 100}} =
             Queue.request(name, {:put, "key", %{payload: String.duplicate("x", 200)}, []})

    assert projected > 100
    assert File.stat!(Path.join(dir, id <> ".jsonl")).size <= 100
  end

  describe "put / claim / ack lifecycle" do
    test "invalid requests preserve a live claim and its durable log", %{dir: dir, id: id} do
      %{pid: pid, name: name} = start_queue!(id: id, dir: dir)
      assert {:ok, _} = Queue.request(name, {:put, "job", %{}, []})
      assert {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      path = Path.join(dir, id <> ".jsonl")
      log = File.read!(path)

      for request <- [
            {:settle, claimed.claim_id, :bogus, []},
            {:claim, 0, nil, :infinity, :all},
            {:claim, 1, nil, -1, :all},
            {:snapshot_page, -1, 100},
            {:snapshot_page, 0, 0},
            :unsupported
          ] do
        assert {:error, :invalid_request} = Queue.request(name, request)
      end

      assert {:error, :invalid_selector} =
               GenServer.call(name, {:claim, 1, nil, :infinity, %{}})

      assert File.read!(path) == log

      assert Process.alive?(pid)
      assert %{pending: 0, claimed: 1} = Queue.request(name, :count)
      assert :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})
    end

    test "snapshot pages and lookup cover records beyond the first bounded page", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir)

      for n <- 1..105 do
        {:ok, _} = Queue.request(name, {:put, "job-#{n}", %{n: n}, []})
      end

      assert {:ok, %{records: first, next_cursor: 100}} =
               GenServer.call(name, {:snapshot_page, 0, 1_000})

      assert length(first) == 100
      assert hd(first).key == "job-1"
      assert hd(first).operation_key == "business-generation:" <> hd(first).generation_id

      assert {:ok, %{records: second, next_cursor: nil}} =
               Queue.request(name, {:snapshot_page, 100, 100})

      assert length(second) == 5
      assert hd(second).key == "job-101"
      assert {:ok, %{key: "job-105"}} = Queue.request(name, {:lookup, "job-105"})
      assert {:error, :not_found} = Queue.request(name, {:lookup, "missing"})
    end
  end

  describe "delayed scheduling" do
    defp controlled_clock do
      {:ok, clock} = Agent.start_link(fn -> 10_000 end)
      {clock, fn -> Agent.get(clock, & &1) end}
    end

    test "delayed release persists and stale owners cannot change the schedule", %{
      dir: dir,
      id: id
    } do
      {clock, now} = controlled_clock()
      %{name: queue, pid: pid} = start_queue!(id: id, dir: dir, clock: now, lease_ms: 100)
      {:ok, _} = Queue.request(queue, {:put, "retry", %{}, []})
      {:ok, [first]} = Queue.request(queue, {:claim, 1, nil, :infinity, :all})
      Agent.update(clock, &(&1 + 100))

      assert {:error, :lease_expired} =
               Queue.request(queue, {:settle, first.claim_id, :release, [delay_ms: 500]})

      {:ok, [second]} = Queue.request(queue, {:claim, 1, nil, :infinity, :all})

      assert {:error, :not_found} =
               Queue.request(queue, {:settle, first.claim_id, :release, [delay_ms: 500]})

      assert :ok = Queue.request(queue, {:settle, second.claim_id, :release, [delay_ms: 300]})
      GenServer.stop(pid)
      %{name: restarted} = start_queue!(id: id, dir: dir, clock: now)
      assert {:ok, []} = Queue.request(restarted, {:claim, 1, "consumer", 10_000, :all})
      Agent.update(clock, &(&1 + 300))

      assert {:ok, [%{key: "retry", not_before_ms: 10_400}]} =
               Queue.request(restarted, {:claim, 1, "consumer", 10_000, :all})
    end
  end

  describe "leases" do
    test "put reclaims an expired lease before updating the same key", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, original} = Queue.request(name, {:put, "job-1", %{n: 1}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      Process.sleep(10)

      assert {:ok, %{id: id, revision: 2, status: :pending}} =
               Queue.request(name, {:put, "job-1", %{n: 2}, []})

      assert id == original.id
      assert {:error, :not_found} = Queue.request(name, {:settle, claimed.claim_id, :ack, []})

      assert {:ok,
              %{records: [%{payload: %{n: 2}, revision: 2, status: :pending}], next_cursor: nil}} =
               Queue.request(name, {:snapshot_page, 0, 100})
    end

    test "put reclaims an expired lease after restart", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, original} = Queue.request(name, {:put, "job-1", %{n: 1}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      GenServer.stop(pid)

      Process.sleep(10)

      %{name: name2} = start_queue!(id: id, dir: dir)

      assert {:ok, %{id: id, revision: 2, status: :pending}} =
               Queue.request(name2, {:put, "job-1", %{n: 2}, []})

      assert id == original.id
      assert {:error, :not_found} = Queue.request(name2, {:settle, claimed.claim_id, :ack, []})
      assert {:ok, [reclaimed]} = Queue.request(name2, {:claim, 1, nil, :infinity, :all})
      assert reclaimed.revision == 2
      assert reclaimed.payload == %{n: 2}
    end

    test "a stale acknowledgement stays dead after a new claim", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, lease_ms: 1)
      Queue.request(name, {:put, "job-1", %{n: 1}, []})
      {:ok, [old_claim]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      Process.sleep(10)

      {:ok, _} = Queue.request(name, {:put, "job-1", %{n: 2}, []})
      {:ok, [new_claim]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      assert new_claim.claim_id != old_claim.claim_id
      assert {:error, :not_found} = Queue.request(name, {:settle, old_claim.claim_id, :ack, []})
      assert %{pending: 0, claimed: 1} = Queue.request(name, :count)
    end

    test "a failed append does not make an expired claim disappear", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      Queue.request(name, {:put, "job-1", %{n: 1}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      Process.sleep(10)
      path = Path.join(dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, :eisdir} = Queue.request(name, {:put, "job-1", %{n: 2}, []})
      assert %{pending: 0, claimed: 1} = Queue.request(name, :count)
      assert {:error, :lease_expired} = Queue.request(name, {:settle, claimed.claim_id, :ack, []})
      GenServer.stop(pid)
    end
  end

  describe "durability" do
    test "a valid final JSON record without newline is normalized before append", %{
      dir: dir,
      id: id
    } do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "first", %{}, []})
      path = Path.join(dir, id <> ".jsonl")
      GenServer.stop(pid)
      File.write!(path, String.trim_trailing(File.read!(path), "\n"))

      %{name: name2, pid: pid2} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name2, {:put, "second", %{}, []})
      GenServer.stop(pid2)

      assert %{name: _name3} = start_queue!(id: id, dir: dir)
    end

    test "torn-tail repair is stable across repeated restart and append", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "kept", %{n: 1}, []})
      path = Path.join(dir, id <> ".jsonl")
      GenServer.stop(pid)
      File.write!(path, File.read!(path) <> "{\"v\":1")

      %{pid: pid2} = start_queue!(id: id, dir: dir)
      GenServer.stop(pid2)
      %{name: name3, pid: pid3} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name3, {:put, "after-repair", %{n: 2}, []})
      GenServer.stop(pid3)

      %{name: name4} = start_queue!(id: id, dir: dir)

      assert {:ok, %{records: records, next_cursor: nil}} =
               Queue.request(name4, {:snapshot_page, 0, 100})

      assert Enum.map(records, & &1.key) == ["kept", "after-repair"]
    end

    test "a claimed record survives restart under its lease, then expires", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, _} = Queue.request(name, {:put, "job-1", %{n: 1}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      GenServer.stop(pid)

      Process.sleep(10)

      %{name: name2} = start_queue!(id: id, dir: dir)
      assert {:ok, [reclaimed]} = Queue.request(name2, {:claim, 1, nil, :infinity, :all})
      assert reclaimed.id == claimed.id
      assert reclaimed.claim_id != claimed.claim_id
    end

    test "live puts continue past replayed record ids", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, %{id: first_id}} = Queue.request(name, {:put, "a", %{}, []})
      {:ok, %{id: second_id}} = Queue.request(name, {:put, "b", %{}, []})
      GenServer.stop(pid)
      assert first_id != second_id

      %{name: name2} = start_queue!(id: id, dir: dir)
      {:ok, %{id: third_id}} = Queue.request(name2, {:put, "c", %{}, []})
      assert third_id not in [first_id, second_id]
    end

    test "a corrupt log fails the start loudly", %{dir: dir, id: id} do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "k", %{n: 1}, []})
      GenServer.stop(pid)
      good = File.read!(path)
      File.write!(path, good <> "not json\n")

      assert {:error, {:queue_corrupt, ^id, 3}} =
               Queue.start_link(id: id, dir: dir, name: :"corrupt_#{unique_id()}")

      [snapshot, command] = String.split(good, "\n", trim: true)
      {:ok, {:put, record}} = command |> JSON.decode!() |> Alto.Persistence.Codec.decode()

      for malformed <- [
            %{record | status: :claimed, claim_id: nil, lease_until_ms: "bad"},
            record |> Map.delete(:key) |> Map.put(:unexpected, "k")
          ] do
        {:ok, encoded} = Alto.Persistence.Codec.encode({:put, malformed})
        File.write!(path, snapshot <> "\n" <> JSON.encode!(encoded) <> "\n")

        assert {:error, :bad_entry} = Queue.start_link(id: id, dir: dir, name: nil)
      end
    end
  end

  describe "bounds" do
    test "a full queue still accepts an in-place update of its pending key", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir, max_records: 1)
      {:ok, _} = Queue.request(name, {:put, "a", %{v: 1}, []})

      assert {:ok, %{revision: 2}} = Queue.request(name, {:put, "a", %{v: 2}, []})
      assert {:error, :queue_full} = Queue.request(name, {:put, "b", %{}, []})
      assert %{pending: 1} = Queue.request(name, :count)
    end

    test "claim and release keep a large record within a small log", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_log_bytes: 4_096)
      {:ok, _} = Queue.request(name, {:put, "large", %{blob: String.duplicate("x", 2_000)}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      assert :ok = Queue.request(name, {:settle, claimed.claim_id, :release, []})
      assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
      assert File.stat!(Path.join(dir, id <> ".jsonl")).size <= 4_096
    end

    test "payloads over the byte bound are rejected, not truncated", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_payload_bytes: 100)

      assert {:error, {:payload_too_large, size}} =
               Queue.request(name, {:put, "big", %{blob: String.duplicate("x", 500)}, []})

      assert is_integer(size) and size > 100
      assert %{pending: 0} = Queue.request(name, :count)
    end

    test "invalid keys and payloads are rejected", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      assert {:error, {:invalid_key, ""}} = Queue.request(name, {:put, "", %{}, []})

      assert {:error, {:invalid_key, _}} =
               Queue.request(name, {:put, String.duplicate("k", 300), %{}, []})

      assert {:error, {:invalid_key, 42}} = Queue.request(name, {:put, 42, %{}, []})
      assert {:error, {:invalid_payload, "no"}} = Queue.request(name, {:put, "k", "no", []})
    end
  end

  test "queue and ledger reject hostile storage ids before creating files", %{dir: dir} do
    directory = Path.join(dir, "logs")

    for module <- [Queue, Alto.OperationLog], id <- ["../escape", "a/b"] do
      assert_raise ArgumentError, ~r/invalid storage id/, fn ->
        module.start_link(id: id, dir: directory, name: nil)
      end
    end

    assert File.ls!(dir) == []
  end

  describe "scheduling input validation" do
    test "invalid scheduling options return errors and keep queue alive", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      for opts <- [
            [unknown: 1],
            [:delay_ms],
            [delay_ms: -1],
            [not_before_ms: nil],
            [delay_ms: 0, delay_ms: 0],
            [delay_ms: 0, not_before_ms: 1]
          ] do
        assert {:error, {:invalid_schedule, ^opts}} =
                 Queue.request(name, {:put, "bad", %{}, opts})
      end

      assert {:ok, _} = Queue.request(name, {:put, "good", %{}, []})
      assert {:ok, [%{key: "good"}]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
    end

    test "invalid persisted record schedule fails startup", %{dir: dir, id: id} do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "k", %{}, []})
      GenServer.stop(pid)
      [snapshot, command] = path |> File.read!() |> String.split("\n", trim: true)
      {:ok, {:put, record}} = command |> JSON.decode!() |> Alto.Persistence.Codec.decode()
      {:ok, malformed} = Alto.Persistence.Codec.encode({:put, %{record | not_before_ms: "bad"}})
      File.write!(path, snapshot <> "\n" <> JSON.encode!(malformed) <> "\n")

      assert {:error, :bad_entry} = Queue.start_link(id: id, dir: dir, name: nil)
    end
  end
end
