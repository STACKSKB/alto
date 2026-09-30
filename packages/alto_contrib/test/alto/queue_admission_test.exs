defmodule Alto.QueueAdmissionTest do
  @moduledoc """
  /conformance: source delivery admission (`:admit` requests) separated
  from business-key upserts (`:put` requests).

  Delivery keys are insert-only and first-wins; blanking (ack or cancel)
  completes the key in a bounded window that survives restart; the window
  expiry honestly re-admits. The `:put` request keeps its pending-update /
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
               Queue.request(name, {:admit, "src:del-1", %{"body" => "first"}, []})

      # Conflicting body, same delivery key: first wins, no update.
      assert {:error, :duplicate} =
               Queue.request(name, {:admit, "src:del-1", %{"body" => "second"}, []})

      assert {:ok, [record]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      assert record.payload == %{"body" => "first"}
      assert record.revision == 1
    end

    test "admit on a claimed key is a conflict", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:admit, "src:del-1", %{}, []})
      {:ok, [_]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      assert {:error, {:key_claimed, "src:del-1"}} =
               Queue.request(name, {:admit, "src:del-1", %{}, []})
    end
  end

  describe "completed window" do
    test "admit after ack stays duplicate, including after restart", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:admit, "src:del-1", %{"body" => "x"}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})

      assert {:error, :duplicate} =
               Queue.request(name, {:admit, "src:del-1", %{"body" => "x"}, []})

      assert %{pending: 0, claimed: 0} = Queue.request(name, :count)
      GenServer.stop(pid)

      %{name: name2} = start_queue!(id: id, dir: dir)

      # No second work item after restart either.
      assert {:error, :duplicate} =
               Queue.request(name2, {:admit, "src:del-1", %{"body" => "x"}, []})

      assert %{pending: 0, claimed: 0} = Queue.request(name2, :count)
      assert {:ok, []} = Queue.request(name2, {:claim, 1, nil, :infinity, :all})
    end

    test "cancel completes the key too; release does not", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:admit, "src:gone", %{}, []})
      :ok = Queue.request(name, {:cancel, "src:gone"})

      assert {:error, :duplicate} = Queue.request(name, {:admit, "src:gone", %{}, []})

      {:ok, _} = Queue.request(name, {:admit, "src:live", %{}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      :ok = Queue.request(name, {:settle, claimed.claim_id, :release, []})

      # Released work is still live: a conflicting admit sees the claim
      # path once re-claimed, and a fresh key still admits.
      assert {:error, :duplicate} = Queue.request(name, {:admit, "src:live", %{}, []})
    end

    test "window eviction honestly re-admits", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_completed: 2)

      for n <- 1..3 do
        key = "src:del-#{n}"
        {:ok, _} = Queue.request(name, {:admit, key, %{}, []})
        {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
        :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})
      end

      # The oldest completion fell out of the window: redelivery re-queues.
      assert {:ok, %{revision: 1}} = Queue.request(name, {:admit, "src:del-1", %{}, []})
      # The recent ones still dedup.
      assert {:error, :duplicate} = Queue.request(name, {:admit, "src:del-3", %{}, []})
    end

    test "a max_completed of zero disables the window", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir, max_completed: 0)
      {:ok, _} = Queue.request(name, {:admit, "src:del-1", %{}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})

      assert {:ok, %{revision: 1}} = Queue.request(name, {:admit, "src:del-1", %{}, []})
    end
  end

  describe "crash recovery" do
    test "commit survives restart: redelivery dedups with no second record", %{
      dir: dir,
      id: id
    } do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, %{id: rec_id}} = Queue.request(name, {:admit, "src:del-1", %{"body" => "x"}, []})
      # Crash between commit and the HTTP 200: the process dies, the log stays.
      GenServer.stop(pid)

      %{name: name2} = start_queue!(id: id, dir: dir)

      assert {:error, :duplicate} =
               Queue.request(name2, {:admit, "src:del-1", %{"body" => "x"}, []})

      assert %{pending: 1, claimed: 0} = Queue.request(name2, :count)
      assert {:ok, [%{id: ^rec_id}]} = Queue.request(name2, {:claim, 1, nil, :infinity, :all})
    end

    test "a torn trailing write is discarded; middle corruption still fails", %{
      dir: dir,
      id: id
    } do
      path = Path.join(dir, id <> ".jsonl")
      File.mkdir_p!(dir)

      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "k", %{n: 1}, []})
      GenServer.stop(pid)
      good = File.read!(path)

      # Torn tail: bytes with no trailing newline that do not decode.
      File.write!(path, good <> "\n" <> "{\"v\": 1, \"type\": \"put\", \"id\": \"rec-2\"")

      %{name: name} = start_queue!(id: id, dir: dir)
      assert %{pending: 1} = Queue.request(name, :count)

      assert {:ok, %{records: [%{key: "k"}], next_cursor: nil}} =
               Queue.request(name, {:snapshot_page, 0, 100})

      # The file was truncated back to the last good byte.
      assert {:ok, contents} = File.read(path)
      assert String.ends_with?(contents, "\n")
      GenServer.stop(name)

      # Corruption anywhere else still fails loudly.
      File.write!(path, "not json\n" <> good <> "\n")

      assert {:error, :invalid_queue_snapshot} =
               Queue.start_link(
                 id: id,
                 dir: dir,
                 name: :"admit_corrupt_#{System.unique_integer([:positive])}"
               )
    end

    test "a failed append changes nothing, including completed state", %{dir: dir, id: id} do
      %{name: name, pid: pid} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:admit, "src:keep", %{}, []})
      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})

      path = Path.join(dir, id <> ".jsonl")
      File.rm!(path)
      File.mkdir!(path)

      assert {:error, _reason} = Queue.request(name, {:settle, claimed.claim_id, :ack, []})
      # The ack did not commit, so the claim is intact and uncompleted.
      assert %{pending: 0, claimed: 1} = Queue.request(name, :count)
      GenServer.stop(pid)
    end
  end

  describe "claim_bounded" do
    test "budgets encoded bytes as well as count, oldest first", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)

      for n <- 1..5 do
        {:ok, _} = Queue.request(name, {:put, "k#{n}", %{pad: String.duplicate("x", 500)}, []})
      end

      # Enough bytes for two records but not three.
      {:ok, [first, _second]} = Queue.request(name, {:claim, 2, nil, :infinity, :all})
      one_size = wire_size(first)

      assert {:ok, fitting} = Queue.request(name, {:claim, 5, nil, 2 + 2 * one_size + 1, :all})
      assert length(fitting) == 2
      assert %{pending: 1, claimed: 4} = Queue.request(name, :count)
    end

    test "a fitting prefix does not inspect records beyond the first oversized record", %{
      dir: dir,
      id: id
    } do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "small", %{text: "deliverable"}, []})
      {:ok, _} = Queue.request(name, {:put, "big", %{text: String.duplicate("x", 5_000)}, []})
      {:ok, invalid} = Queue.request(name, {:put, "invalid", %{text: <<255>>}, []})

      assert {:ok, [%{key: "small"} = claimed]} =
               Queue.request(name, {:claim, 3, nil, 1_000, :all})

      assert %{pending: 2, claimed: 1} = Queue.request(name, :count)
      assert :ok = Queue.request(name, {:settle, claimed.claim_id, :ack, []})
      assert :ok = Queue.request(name, {:cancel, "big"})

      assert {:error, {:queue_unencodable, id}} =
               Queue.request(name, {:claim, 1, nil, 1_000, :all})

      assert id == invalid.id
      assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
    end

    test "a lone oversized head leases nothing and names the record", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      {:ok, _} = Queue.request(name, {:put, "big", %{pad: String.duplicate("x", 5_000)}, []})

      assert {:error, {:record_too_large, %{key: "big", size: size}}} =
               Queue.request(name, {:claim, 5, nil, 100, :all})

      assert is_integer(size) and size > 100
      # Still pending, no invisible lease.
      assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
    end

    test "escaped JSON expansion counts against the budget", %{dir: dir, id: id} do
      %{name: name} = start_queue!(id: id, dir: dir)
      # Quotes expand on the wire: term bytes understate the envelope.
      {:ok, _} = Queue.request(name, {:put, "q", %{pad: String.duplicate("\"", 1_000)}, []})

      {:ok, [claimed]} = Queue.request(name, {:claim, 1, nil, :infinity, :all})
      expanded = wire_size(claimed)
      assert expanded > 2_000
      :ok = Queue.request(name, {:settle, claimed.claim_id, :release, []})

      assert {:error, {:record_too_large, %{key: "q"}}} =
               Queue.request(name, {:claim, 1, nil, 1_500, :all})

      assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
    end
  end

  defp wire_size(record) do
    record |> Alto.Contrib.Protocol.encode_term() |> JSON.encode!() |> byte_size()
  end
end
