defmodule Alto.QueueCompactionTest do
  use ExUnit.Case, async: true
  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-compact-#{System.unique_integer([:positive])}")
    clock = :atomics.new(1, signed: false)
    :atomics.put(clock, 1, 1_000)

    opts = [
      id: "messages",
      dir: dir,
      name: nil,
      max_completed: 3,
      clock: fn -> :atomics.get(clock, 1) end,
      lease_ms: 100
    ]

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, opts: opts, clock: clock, path: Path.join(dir, "messages.jsonl")}
  end

  defp churn(q, values) do
    for n <- values do
      assert {:ok, _} = Queue.request(q, {:admit, "del-#{n}", %{n: n}, []})
      assert :ok = Queue.request(q, {:cancel_pending, "del-#{n}"})
    end
  end

  test "ordinary replay matches live transitions, including exact owners and the injected clock",
       c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.request(q, {:put, "update", %{v: 1}, []})
    assert {:ok, _} = Queue.request(q, {:put, "update", %{v: 2}, [delay_ms: 50]})
    assert {:ok, _} = Queue.request(q, {:admit, "claimed", %{v: {:native, :term}}, []})
    assert {:ok, [claim]} = Queue.request(q, {:claim, 1, %{owner: {:worker, 1}}, :infinity, :all})
    assert :ok = Queue.request(q, {:settle, claim.claim_id, :release, []})
    assert {:ok, [_]} = Queue.request(q, {:claim, 1, %{owner: {:worker, 2}}, :infinity, :all})
    churn(q, 1..3)
    assert {:ok, _} = Queue.request(q, {:restore, "operation", "generation", %{v: 3}, []})
    before = Queue.request(q, {:snapshot_page, 0, 100})
    assert {:ok, %{records: records, next_cursor: nil}} = before
    assert Enum.all?(records, &(&1.at_ms == 1_000))
    stop_supervised!(Queue)

    q = start_supervised!({Queue, c.opts})
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
    assert {:error, :duplicate} = Queue.request(q, {:admit, "del-3", %{}, []})
  end

  test "compact and restart preserve all live fields and retained delivery identities", c do
    q = start_supervised!({Queue, c.opts})
    churn(q, 1..20)

    assert {:ok, _} =
             Queue.request(
               q,
               {:admit, "live-claim", %{exact: {:tuple, <<0, 255>>, [1, :atom]}}, []}
             )

    assert {:ok, [claimed]} = Queue.request(q, {:claim, 1, %{role: :worker}, :infinity, :all})
    assert {:ok, _} = Queue.request(q, {:put, "later", %{v: 1}, [not_before_ms: 1_500]})
    assert {:ok, _} = Queue.request(q, {:put, "later", %{v: 2}, [not_before_ms: 1_600]})
    assert {:ok, _} = Queue.request(q, {:admit, "delivery", %{v: 3}, []})

    assert {:ok, _} =
             Queue.request(
               q,
               {:restore, "operation", "generation", %{v: 4}, [recovery_revision: 7]}
             )

    before = Queue.request(q, {:snapshot_page, 0, 100})
    assert {:ok, stats} = Queue.request(q, :compact, :infinity)
    assert stats.after_bytes < stats.before_bytes
    assert stats.live_records == 4
    assert stats.completed_keys == 3
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
    stop_supervised!(Queue)
    q = start_supervised!({Queue, c.opts})
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
    assert {:error, :duplicate} = Queue.request(q, {:admit, "del-20", %{}, []})
    assert {:error, :duplicate} = Queue.request(q, {:admit, "delivery", %{}, []})
    assert :ok = Queue.request(q, {:settle, claimed.claim_id, :ack, []})
    assert {:ok, records} = Queue.request(q, {:claim, 10, "other", :infinity, :all})
    refute Enum.any?(records, &(&1.key == "later"))
    assert Enum.map(records, & &1.admission) == [:delivery, :recovery]
    :atomics.put(c.clock, 1, 1_600)
    assert {:ok, [later | _]} = Queue.request(q, {:claim, 10, "after-due", :infinity, :all})
    assert later.key == "later"
  end

  test "automatic compaction permits sustained churn within the configured log bound", c do
    opts = Keyword.merge(c.opts, auto_compact: true, max_log_bytes: 4_000)
    q = start_supervised!({Queue, opts})
    assert {:ok, _} = Queue.request(q, {:admit, "live", %{v: 1}, []})
    assert {:ok, [claimed]} = Queue.request(q, {:claim, 1, "owner", :infinity, :all})
    churn(q, 1..100)
    assert File.stat!(c.path).size <= 4_000
    assert {:ok, ^claimed} = Queue.request(q, {:lookup, "live"})
    stop_supervised!(Queue)
    q = start_supervised!({Queue, opts})
    assert {:ok, ^claimed} = Queue.request(q, {:lookup, "live"})

    for n <- 98..100,
        do: assert({:error, :duplicate} = Queue.request(q, {:admit, "del-#{n}", %{}, []}))

    assert {:ok, _} = Queue.request(q, {:admit, "del-1", %{}, []})
    assert :ok = Queue.request(q, {:settle, claimed.claim_id, :ack, []})
  end

  test "full canonical state fails without replacing bytes or discarding pending work", c do
    q = start_supervised!({Queue, c.opts})

    assert {:ok, _} =
             Queue.request(q, {:put, "pending", %{payload: String.duplicate("x", 800)}, []})

    bytes = File.read!(c.path)
    before = Queue.request(q, {:snapshot_page, 0, 100})
    :sys.replace_state(q, &%{&1 | max_log_bytes: 100, auto_compact: true})
    assert {:error, {:queue_log_too_large, _, 100}} = Queue.request(q, :compact, :infinity)
    assert {:error, {:queue_log_too_large, _, 100}} = Queue.request(q, {:put, "new", %{}, []})
    assert File.read!(c.path) == bytes
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
  end

  test "default queues keep append-only history and refuse a full log", c do
    q = start_supervised!({Queue, Keyword.put(c.opts, :max_log_bytes, 600)})
    assert {:ok, _} = Queue.request(q, {:admit, "first", %{}, []})
    assert :ok = Queue.request(q, {:cancel_pending, "first"})
    bytes = File.read!(c.path)

    assert {:error, {:queue_log_too_large, _, 600}} =
             Queue.request(q, {:admit, "second", %{payload: String.duplicate("x", 500)}, []})

    assert File.read!(c.path) == bytes
    assert {:error, :duplicate} = Queue.request(q, {:admit, "first", %{}, []})
  end

  test "record IDs do not regress after all records are completed and compacted", c do
    q = start_supervised!({Queue, c.opts})
    churn(q, 1..4)
    assert {:ok, _} = Queue.request(q, :compact, :infinity)
    churn(q, 5..8)
    stop_supervised!(Queue)
    q = start_supervised!({Queue, c.opts})
    assert {:ok, %{id: 9}} = Queue.request(q, {:admit, "new", %{}, []})
  end

  test "an incomplete compacted prefix fails while a torn later append is repaired", c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.request(q, {:admit, "preserve", %{body: "unread"}, []})
    assert {:ok, _} = Queue.request(q, :compact, :infinity)
    before = Queue.request(q, {:snapshot_page, 0, 100})
    stop_supervised!(Queue)
    bytes = File.read!(c.path)
    File.write!(c.path, "")
    assert {:error, :invalid_queue_snapshot} = Queue.start_link(c.opts)
    File.write!(c.path, binary_part(bytes, 0, byte_size(bytes) - 12))
    assert {:error, :invalid_queue_snapshot} = Queue.start_link(c.opts)
    File.write!(c.path, bytes <> ~s({"v":1,"type":"claim"))
    q = start_supervised!({Queue, c.opts})
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
    assert File.read!(c.path) == bytes
  end

  test "snapshots use the queue byte bound rather than the session-log bound", c do
    opts = Keyword.put(c.opts, :max_payload_bytes, 5_000_000)
    q = start_supervised!({Queue, opts})
    payload = %{body: String.duplicate("x", 4_100_000)}
    for n <- 1..3, do: assert({:ok, _} = Queue.request(q, {:put, "large-#{n}", payload, []}))
    before = Queue.request(q, {:snapshot_page, 0, 100})
    assert {:ok, %{after_bytes: bytes}} = Queue.request(q, :compact, :infinity)
    assert bytes > 16_000_000
    stop_supervised!(Queue)
    q = start_supervised!({Queue, opts})
    assert Queue.request(q, {:snapshot_page, 0, 100}) == before
  end

  test "failed initialization does not leave an empty log that blocks retry", c do
    assert {:error, {:queue_log_too_large, _, 1}} =
             Queue.start_link(Keyword.put(c.opts, :max_log_bytes, 1))

    refute File.exists?(c.path)
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.request(q, {:put, "first", %{}, []})
  end

  test "unpersistable payloads fail without changing live or replayed state", c do
    q = start_supervised!({Queue, c.opts})

    assert {:error, :not_portable_or_too_large} =
             Queue.request(q, {:put, "bad", %{pid: self()}, []})

    assert Queue.request(q, :count) == %{pending: 0, claimed: 0}
    stop_supervised!(Queue)
    q = start_supervised!({Queue, c.opts})
    assert Queue.request(q, :count) == %{pending: 0, claimed: 0}
  end

  test "a repeated or foreign retained-state header fails closed", c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.request(q, :compact, :infinity)
    stop_supervised!(Queue)
    bytes = File.read!(c.path)
    File.write!(c.path, bytes <> bytes)
    assert {:error, _} = Queue.start_link(c.opts)
    header = bytes |> String.trim() |> JSON.decode!() |> Map.put("queue", "foreign")
    File.write!(c.path, JSON.encode!(header) <> "\n")
    assert {:error, :invalid_queue_snapshot} = Queue.start_link(c.opts)
  end
end
