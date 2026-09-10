defmodule Alto.QueueAdmissionTest do
  @moduledoc """
  /conformance: source delivery admission (`admit/3`) separated
  from business-key upserts (`put/3`).

  Delivery keys are insert-only and first-wins; blanking (ack or cancel)
  completes the key in a bounded window that survives restart; the window
  expiry honestly re-admits. `put/3` keeps its pending-update /
  claimed-conflict / blanked-requeue contract untouched.
  """

  use ExUnit.Case, async: true

  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-admit-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, id: "q" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  defp start_queue!(opts) do
    name = :"admit_queue_#{System.unique_integer([:positive])}"
    {:ok, pid} = Queue.start_link(Keyword.put(opts, :name, name))
    %{pid: pid, name: name}
  end

  describe "admit identity" do
    test "a fresh key admits; a pending redelivery duplicates without touching bytes", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir)

      assert {:ok, %{revision: 1, status: :pending}} =
               Queue.admit(name, "src:del-1", %{"body" => "first"})

      # Conflicting body, same delivery key: first wins, no update.
      assert {:error, :duplicate} = Queue.admit(name, "src:del-1", %{"body" => "second"})

      assert {:ok, [record]} = Queue.claim(name)
      assert record.payload == %{"body" => "first"}
      assert record.revision == 1
    end

    test "admit on a claimed key is a conflict", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.admit(name, "src:del-1", %{})
      {:ok, [_]} = Queue.claim(name)

      assert {:error, {:key_claimed, "src:del-1"}} = Queue.admit(name, "src:del-1", %{})
    end

    test "put keeps business upsert semantics alongside admit", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      # Business keys still update in place.
      {:ok, _} = Queue.put(name, "job-1", %{total: 10})
      assert {:ok, %{revision: 2}} = Queue.put(name, "job-1", %{total: 12})

      # Delivery keys never update.
      {:ok, _} = Queue.admit(name, "src:del-9", %{n: 1})
      assert {:error, :duplicate} = Queue.admit(name, "src:del-9", %{n: 2})
    end
  end

  describe "completed window" do
    test "admit after ack stays duplicate, including after restart", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.admit(name, "src:del-1", %{"body" => "x"})
      {:ok, [claimed]} = Queue.claim(name)
      :ok = Queue.ack(name, claimed.claim_id)

      assert {:error, :duplicate} = Queue.admit(name, "src:del-1", %{"body" => "x"})
      assert %{pending: 0, claimed: 0} = Queue.count(name)
      GenServer.stop(pid)

      %{name: name2} = start_queue!(id: id, dir: dir)

      # No second work item after restart either.
      assert {:error, :duplicate} = Queue.admit(name2, "src:del-1", %{"body" => "x"})
      assert %{pending: 0, claimed: 0} = Queue.count(name2)
      assert {:ok, []} = Queue.claim(name2)
    end

    test "cancel completes the key too; release does not", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.admit(name, "src:gone", %{})
      :ok = Queue.cancel(name, "src:gone")

      assert {:error, :duplicate} = Queue.admit(name, "src:gone", %{})

      {:ok, _} = Queue.admit(name, "src:live", %{})
      {:ok, [claimed]} = Queue.claim(name)
      :ok = Queue.release(name, claimed.claim_id)

      # Released work is still live: a conflicting admit sees the claim
      # path once re-claimed, and a fresh key still admits.
      assert {:error, :duplicate} = Queue.admit(name, "src:live", %{})
    end

    test "window eviction honestly re-admits", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_completed: 2)

      for n <- 1..3 do
        key = "src:del-#{n}"
        {:ok, _} = Queue.admit(name, key, %{})
        {:ok, [claimed]} = Queue.claim(name)
        :ok = Queue.ack(name, claimed.claim_id)
      end

      # The oldest completion fell out of the window: redelivery re-queues.
      assert {:ok, %{revision: 1}} = Queue.admit(name, "src:del-1", %{})
      # The recent ones still dedup.
      assert {:error, :duplicate} = Queue.admit(name, "src:del-3", %{})
    end

    test "a max_completed of zero disables the window", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_completed: 0)
      {:ok, _} = Queue.admit(name, "src:del-1", %{})
      {:ok, [claimed]} = Queue.claim(name)
      :ok = Queue.ack(name, claimed.claim_id)

      assert {:ok, %{revision: 1}} = Queue.admit(name, "src:del-1", %{})
    end
  end

  describe "crash recovery" do
    test "commit survives restart: redelivery dedups with no second record", %{
      dir: dir,
      id: id
    } do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, %{id: rec_id}} = Queue.admit(name, "src:del-1", %{"body" => "x"})
      # Crash between commit and the HTTP 200: the process dies, the log stays.
      GenServer.stop(pid)

      %{name: name2} = start_queue!(id: id, dir: dir)
      assert {:error, :duplicate} = Queue.admit(name2, "src:del-1", %{"body" => "x"})
      assert %{pending: 1, claimed: 0} = Queue.count(name2)
      assert {:ok, [%{id: ^rec_id}]} = Queue.claim(name2)
    end

    test "a torn trailing write is discarded; middle corruption still fails", %{
      dir: dir,
      id: id
    } do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      good =
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

      # Torn tail: bytes with no trailing newline that do not decode.
      File.write!(path, good <> "\n" <> "{\"v\": 1, \"type\": \"put\", \"id\": \"rec-2\"")

      %{name: name} = start_queue!(id: id, dir: dir)
      assert %{pending: 1} = Queue.count(name)
      assert [%{key: "k"}] = Queue.records(name)

      # The file was truncated back to the last good byte.
      assert {:ok, contents} = File.read(path)
      assert String.ends_with?(contents, "\n")
      GenServer.stop(name)

      # Corruption anywhere else still fails loudly.
      File.write!(path, "not json\n" <> good <> "\n")

      assert {:error, {:queue_corrupt, ^id, 1}} =
               Queue.start_link(
                 id: id,
                 dir: dir,
                 name: :"admit_corrupt_#{System.unique_integer([:positive])}"
               )
    end

    test "a failed append changes nothing, including completed state", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.admit(name, "src:keep", %{})
      {:ok, [claimed]} = Queue.claim(name)

      path = Path.join(dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, _reason} = Queue.ack(name, claimed.claim_id)
      # The ack did not commit, so the claim is intact and uncompleted.
      assert %{pending: 0, claimed: 1} = Queue.count(name)
      GenServer.stop(pid)
    end
  end

  describe "old-log import" do
    test "pre-namespace logs load with live work intact", %{dir: dir, id: id} do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      put = fn rec_id, key ->
        JSON.encode!(%{
          "v" => 1,
          "type" => "put",
          "id" => rec_id,
          "key" => key,
          "payload" => Alto.Session.encode_term(%{n: 1}),
          "revision" => 1,
          "at_ms" => 1,
          "queue" => id
        })
      end

      File.write!(path, put.("rec-1", "del-1") <> "\n" <> put.("rec-2", "job-9") <> "\n")

      assert {:error, {:queue_migration_required, ^id, :legacy_admission}} =
               Queue.start_link(id: id, dir: dir, name: nil)

      %{name: name} = start_queue!(id: id, dir: dir, legacy_admission: :business)
      assert %{pending: 2} = Queue.count(name)
      assert {:ok, [_, _]} = Queue.claim(name, 2)
    end
  end

  describe "claim_bounded" do
    test "budgets encoded bytes as well as count, oldest first", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      for n <- 1..5 do
        {:ok, _} = Queue.put(name, "k#{n}", %{pad: String.duplicate("x", 500)})
      end

      # Enough bytes for two records but not three.
      {:ok, [first, _second]} = Queue.claim(name, 2, nil)
      one_size = wire_size(first)

      assert {:ok, fitting} = Queue.claim_bounded(name, 5, nil, 2 + 2 * one_size + 1)
      assert length(fitting) == 2
      assert %{pending: 1, claimed: 4} = Queue.count(name)
    end

    test "a lone oversized head leases nothing and names the record", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.put(name, "big", %{pad: String.duplicate("x", 5_000)})

      assert {:error, {:record_too_large, %{key: "big", size: size}}} =
               Queue.claim_bounded(name, 5, nil, 100)

      assert is_integer(size) and size > 100
      # Still pending, no invisible lease.
      assert %{pending: 1, claimed: 0} = Queue.count(name)
    end

    test "escaped JSON expansion counts against the budget", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      # Quotes expand on the wire: term bytes understate the envelope.
      {:ok, _} = Queue.put(name, "q", %{pad: String.duplicate("\"", 1_000)})

      {:ok, [claimed]} = Queue.claim(name, 1, nil)
      expanded = wire_size(claimed)
      assert expanded > 2_000
      :ok = Queue.release(name, claimed.claim_id)

      assert {:error, {:record_too_large, %{key: "q"}}} =
               Queue.claim_bounded(name, 1, nil, 1_500)

      assert %{pending: 1, claimed: 0} = Queue.count(name)
    end
  end

  defp wire_size(record) do
    record |> Alto.Protocol.encode_term() |> JSON.encode!() |> byte_size()
  end
end
