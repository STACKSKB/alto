defmodule Alto.QueueTest do
  @moduledoc """
  Durable claim/ack queue coverage: put/claim/ack lifecycle, key dedup
  semantics (pending update, claimed conflict, blanked re-queue), leases
  and crash recovery across restart, cancellation, bounds, and loud
  corruption — the integration contract "durable queue" contract.
  """

  use ExUnit.Case, async: true

  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-queue-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, id: unique_id()}
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "alto-queue-test-#{System.unique_integer([:positive])}")
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

    assert {:error, {:queue_log_too_large, projected, 100}} =
             Queue.put(name, "key", %{payload: String.duplicate("x", 200)})

    assert projected > 100
    assert File.stat!(Path.join(dir, id <> ".jsonl")).size == 0
  end

  describe "put / claim / ack lifecycle" do
    test "put queues a pending record with revision 1", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      assert {:ok, %{revision: 1, status: :pending}} = Queue.put(name, "job-1", %{n: 1})
      assert %{pending: 1, claimed: 0} = Queue.count(name)
    end

    test "claim returns oldest pending first and marks claimed", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      Queue.put(name, "a", %{i: 1})
      Queue.put(name, "b", %{i: 2})

      assert {:ok, [first, second]} = Queue.claim(name, 2, "station-1")
      assert %{key: "a", status: :claimed, claimed_by: "station-1"} = first
      assert %{key: "b"} = second
      assert [%{claim_id: claim_id}] = [first]
      assert is_binary(claim_id) and claim_id != ""
      assert %{pending: 0, claimed: 2} = Queue.count(name)
    end

    test "ack blanks the record; blanked records stay gone", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      assert :ok = Queue.ack(name, claimed.claim_id)
      assert %{pending: 0, claimed: 0} = Queue.count(name)
      assert {:ok, []} = Queue.claim(name)
      assert {:error, :not_found} = Queue.ack(name, claimed.claim_id)
    end

    test "ack of an unknown claim id is not_found", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      assert {:error, :not_found} = Queue.ack(name, "clm-none")
    end

    test "release returns the record to pending", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      assert :ok = Queue.release(name, claimed.claim_id)
      assert %{pending: 1, claimed: 0} = Queue.count(name)

      # A fresh claim is a fresh lease: the old claim id is dead.
      {:ok, [reclaimed]} = Queue.claim(name)
      assert reclaimed.id == claimed.id
      assert reclaimed.claim_id != claimed.claim_id
      assert {:error, :not_found} = Queue.release(name, claimed.claim_id)
    end

    test "snapshot pages and lookup cover records beyond the first bounded page", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir)

      for n <- 1..105 do
        {:ok, _} = Queue.put(name, "job-#{n}", %{n: n})
      end

      assert {:ok, %{records: first, next_cursor: 100}} = Queue.snapshot_page(name, 0, 100)
      assert length(first) == 100
      assert hd(first).key == "job-1"

      assert {:ok, %{records: second, next_cursor: nil}} = Queue.snapshot_page(name, 100, 100)
      assert length(second) == 5
      assert hd(second).key == "job-101"
      assert {:ok, %{key: "job-105"}} = Queue.lookup(name, "job-105")
      assert {:error, :not_found} = Queue.lookup(name, "missing")
    end
  end

  describe "key dedup semantics" do
    test "business generations survive updates and rotate after completion", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      {:ok, first} = Queue.put(name, "job-1", %{v: 1})
      [first_view] = Queue.records(name)
      assert first_view.generation_id =~ "gen-"

      {:ok, updated} = Queue.put(name, "job-1", %{v: 2})
      [updated_view] = Queue.records(name)
      assert updated.id == first.id
      assert updated_view.generation_id == first_view.generation_id

      {:ok, [claimed]} = Queue.claim(name)
      :ok = Queue.ack(name, claimed.claim_id)
      {:ok, _} = Queue.put(name, "job-1", %{v: 3})
      [next_view] = Queue.records(name)
      refute next_view.generation_id == first_view.generation_id
    end

    test "put on a pending key updates payload and bumps revision in place", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, first} = Queue.put(name, "job-1", %{total: 10})
      {:ok, second} = Queue.put(name, "job-1", %{total: 12})

      assert first.id == second.id
      assert second.revision == 2
      assert {:ok, [%{payload: %{total: 12}, revision: 2}]} = Queue.claim(name)
      assert %{pending: 0} = Queue.count(name)
    end

    test "put on a claimed key is a conflict, not a shadow record", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "job-1", %{total: 10})
      {:ok, [claimed]} = Queue.claim(name)

      assert {:error, {:key_claimed, "job-1"}} = Queue.put(name, "job-1", %{total: 12})
      assert %{pending: 0, claimed: 1} = Queue.count(name)
      assert claimed.key == "job-1"
    end

    test "put on a blanked key re-queues as a new record", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, first} = Queue.put(name, "job-1", %{total: 10})
      {:ok, [claimed]} = Queue.claim(name)
      :ok = Queue.ack(name, claimed.claim_id)

      {:ok, second} = Queue.put(name, "job-1", %{total: 99})
      assert first.id != second.id
      second_id = second.id
      assert {:ok, [%{id: ^second_id, payload: %{total: 99}, revision: 1}]} = Queue.claim(name)
    end
  end

  describe "cancellation" do
    test "cancel blanks the pending record for a key", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})

      assert :ok = Queue.cancel(name, "job-1")
      assert %{pending: 0} = Queue.count(name)
      assert {:error, :not_found} = Queue.cancel(name, "job-1")
    end

    test "cancel blanks a claimed record too", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      assert :ok = Queue.cancel(name, "job-1")
      assert %{pending: 0, claimed: 0} = Queue.count(name)
      assert {:error, :not_found} = Queue.ack(name, claimed.claim_id)
    end
  end

  describe "leases" do
    @tag :lease
    test "an expired lease reverts the record to pending", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      Process.sleep(10)

      # An ack past its lease is refused: the claim is dead, not the record.
      assert {:error, :lease_expired} = Queue.ack(name, claimed.claim_id)

      # The record is claimable again, under a fresh lease.
      assert {:ok, [reclaimed]} = Queue.claim(name)
      assert reclaimed.id == claimed.id
      assert reclaimed.claim_id != claimed.claim_id
    end

    test "put reclaims an expired lease before updating the same key", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, original} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      Process.sleep(10)

      assert {:ok, %{id: id, revision: 2, status: :pending}} =
               Queue.put(name, "job-1", %{n: 2})

      assert id == original.id
      assert {:error, :not_found} = Queue.ack(name, claimed.claim_id)
      assert [%{payload: %{n: 2}, revision: 2, status: :pending}] = Queue.records(name)
    end

    test "put reclaims an expired lease after restart", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, original} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)
      GenServer.stop(pid)

      Process.sleep(10)

      %{name: name2} = start_queue!(id: id, dir: dir)

      assert {:ok, %{id: id, revision: 2, status: :pending}} =
               Queue.put(name2, "job-1", %{n: 2})

      assert id == original.id
      assert {:error, :not_found} = Queue.ack(name2, claimed.claim_id)
      assert {:ok, [reclaimed]} = Queue.claim(name2)
      assert reclaimed.revision == 2
      assert reclaimed.payload == %{n: 2}
    end

    test "a stale acknowledgement stays dead after a new claim", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, lease_ms: 1)
      Queue.put(name, "job-1", %{n: 1})
      {:ok, [old_claim]} = Queue.claim(name)

      Process.sleep(10)

      {:ok, _} = Queue.put(name, "job-1", %{n: 2})
      {:ok, [new_claim]} = Queue.claim(name)

      assert new_claim.claim_id != old_claim.claim_id
      assert {:error, :not_found} = Queue.ack(name, old_claim.claim_id)
      assert %{pending: 0, claimed: 1} = Queue.count(name)
    end

    test "a failed append does not make an expired claim disappear", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)

      Process.sleep(10)
      path = Path.join(dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, :eisdir} = Queue.put(name, "job-1", %{n: 2})
      assert %{pending: 0, claimed: 1} = Queue.count(name)
      assert {:error, :lease_expired} = Queue.ack(name, claimed.claim_id)
      GenServer.stop(pid)
    end
  end

  describe "durability" do
    test "ambiguous pre-identity records require an explicit migration choice", %{
      dir: dir,
      id: id
    } do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      legacy = %{
        "v" => 1,
        "type" => "put",
        "id" => "rec-1",
        "key" => "legacy-key",
        "payload" => Alto.Session.encode_term(%{v: 1}),
        "revision" => 1,
        "at_ms" => 1,
        "queue" => id
      }

      File.write!(path, JSON.encode!(legacy) <> "\n")

      assert {:error, {:queue_migration_required, ^id, :legacy_admission}} =
               Queue.start_link(id: id, dir: dir, name: nil)

      %{name: name} = start_queue!(id: id, dir: dir, legacy_admission: :business)
      [record] = Queue.records(name)
      assert record.admission == :business
      assert record.generation_id == "legacy-#{id}-rec-1"
    end

    test "a valid final JSON record without newline is normalized before append", %{
      dir: dir,
      id: id
    } do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "first", %{})
      path = Path.join(dir, id <> ".jsonl")
      GenServer.stop(pid)
      File.write!(path, String.trim_trailing(File.read!(path), "\n"))

      %{name: name2, pid: pid2} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name2, "second", %{})
      GenServer.stop(pid2)

      assert %{name: _name3} = start_queue!(id: id, dir: dir)
    end

    test "torn-tail repair is stable across repeated restart and append", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "kept", %{n: 1})
      path = Path.join(dir, id <> ".jsonl")
      GenServer.stop(pid)
      File.write!(path, File.read!(path) <> "{\"v\":1")

      %{pid: pid2} = start_queue!(id: id, dir: dir)
      GenServer.stop(pid2)
      %{name: name3, pid: pid3} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name3, "after-repair", %{n: 2})
      GenServer.stop(pid3)

      %{name: name4} = start_queue!(id: id, dir: dir)
      assert Enum.map(Queue.records(name4), & &1.key) == ["kept", "after-repair"]
    end

    test "records survive a restart, blanks included", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, kept} = Queue.put(name, "keep", %{n: 1})
      {:ok, _} = Queue.put(name, "blanked", %{n: 2})
      {:ok, [_, _] = claimed} = Queue.claim(name, 2)

      blanked = Enum.find(claimed, &(&1.key == "blanked"))
      :ok = Queue.ack(name, blanked.claim_id)
      GenServer.stop(pid)

      %{name: name2} = start_queue!(id: id, dir: dir)
      assert %{pending: 0, claimed: 1} = Queue.count(name2)

      kept_id = kept.id

      assert [%{id: ^kept_id, key: "keep", payload: %{n: 1}, revision: 1}] =
               Queue.records(name2) |> Enum.filter(&(&1.key == "keep"))
    end

    test "a claimed record survives restart under its lease, then expires", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir, lease_ms: 1)
      {:ok, _} = Queue.put(name, "job-1", %{n: 1})
      {:ok, [claimed]} = Queue.claim(name)
      GenServer.stop(pid)

      Process.sleep(10)

      %{name: name2} = start_queue!(id: id, dir: dir)
      assert {:ok, [reclaimed]} = Queue.claim(name2)
      assert reclaimed.id == claimed.id
      assert reclaimed.claim_id != claimed.claim_id
    end

    test "live puts continue past replayed record ids", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, %{id: first_id}} = Queue.put(name, "a", %{})
      {:ok, %{id: second_id}} = Queue.put(name, "b", %{})
      GenServer.stop(pid)
      assert first_id != second_id

      %{name: name2} = start_queue!(id: id, dir: dir)
      {:ok, %{id: third_id}} = Queue.put(name2, "c", %{})
      assert third_id not in [first_id, second_id]
    end

    test "a corrupt log fails the start loudly", %{dir: dir, id: id} do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      valid_put =
        JSON.encode!(%{
          "v" => 1,
          "type" => "put",
          "id" => "rec-1",
          "key" => "k",
          "payload" => Alto.Session.encode_term(%{n: 1}),
          "revision" => 1,
          "mode" => "business",
          "generation_id" => "gen-fixture",
          "at_ms" => 1,
          "queue" => id
        })

      File.write!(path, valid_put <> "\nnot json\n")

      assert {:error, {:queue_corrupt, ^id, 2}} =
               Queue.start_link(id: id, dir: dir, name: :"corrupt_#{unique_id()}")
    end
  end

  describe "bounds" do
    test "a full queue still accepts an in-place update of its pending key", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir, max_records: 1)
      {:ok, _} = Queue.put(name, "a", %{v: 1})

      assert {:ok, %{revision: 2}} = Queue.put(name, "a", %{v: 2})
      assert {:error, :queue_full} = Queue.put(name, "b", %{})
      assert %{pending: 1} = Queue.count(name)
    end

    test "claim ids are unique random handles, not monotonic integers", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      Queue.put(name, "a", %{})
      Queue.put(name, "b", %{})
      {:ok, [first, second]} = Queue.claim(name, 2)

      assert first.claim_id != second.claim_id
      assert String.starts_with?(first.claim_id, "clm-")
      refute first.claim_id =~ ~r/^clm-\d+$/
    end

    test "payloads over the byte bound are rejected, not truncated", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_payload_bytes: 100)

      assert {:error, {:payload_too_large, size}} =
               Queue.put(name, "big", %{blob: String.duplicate("x", 500)})

      assert is_integer(size) and size > 100
      assert %{pending: 0} = Queue.count(name)
    end

    test "the record count bound is enforced", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_records: 2)
      {:ok, _} = Queue.put(name, "a", %{})
      {:ok, _} = Queue.put(name, "b", %{})

      assert {:error, :queue_full} = Queue.put(name, "c", %{})
    end

    test "updating a pending key does not consume new capacity", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_records: 2)
      {:ok, _} = Queue.put(name, "a", %{v: 1})
      {:ok, _} = Queue.put(name, "a", %{v: 2})
      {:ok, _} = Queue.put(name, "b", %{})

      assert %{pending: 2} = Queue.count(name)
    end

    test "invalid keys and payloads are rejected", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      assert {:error, {:invalid_key, ""}} = Queue.put(name, "", %{})
      assert {:error, {:invalid_key, _}} = Queue.put(name, String.duplicate("k", 300), %{})
      assert {:error, {:invalid_key, 42}} = Queue.put(name, 42, %{})
      assert {:error, {:invalid_payload, "no"}} = Queue.put(name, "k", "no")
    end
  end

  describe "id validation" do
    test "hostile ids are refused before touching the filesystem" do
      assert {:error, {:invalid_queue_id, "../escape"}} = Queue.validate_id("../escape")
      assert {:error, {:invalid_queue_id, "a/b"}} = Queue.validate_id("a/b")
      assert :ok = Queue.validate_id("jobs-1")
    end

    test "start_link raises on an invalid id" do
      assert_raise ArgumentError, ~r/invalid queue id/, fn ->
        Queue.start_link(id: "../escape", dir: tmp_root(), name: unique_id())
      end
    end
  end
end
