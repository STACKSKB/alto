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
      assert {:ok, _} = Queue.admit(q, "del-#{n}", %{n: n})
      assert :ok = Queue.cancel_pending(q, "del-#{n}")
    end
  end

  test "compact and restart preserve all live fields and retained delivery identities", c do
    q = start_supervised!({Queue, c.opts})
    churn(q, 1..20)
    assert {:ok, _} = Queue.admit(q, "live-claim", %{exact: {:tuple, <<0, 255>>, [1, :atom]}})
    assert {:ok, [claimed]} = Queue.claim(q, 1, %{role: :worker})
    assert {:ok, _} = Queue.put(q, "later", %{v: 1}, not_before_ms: 1_500)
    assert {:ok, _} = Queue.put(q, "later", %{v: 2}, not_before_ms: 1_600)
    assert {:ok, _} = Queue.admit(q, "delivery", %{v: 3})
    assert {:ok, _} = Queue.restore(q, "operation", "generation", %{v: 4}, recovery_revision: 7)
    before = Queue.snapshot(q)
    assert {:ok, stats} = Queue.compact(q)
    assert stats.after_bytes < stats.before_bytes
    assert stats.live_records == 4
    assert stats.completed_keys == 3
    assert Queue.snapshot(q) == before
    stop_supervised!(Queue)
    q = start_supervised!({Queue, c.opts})
    assert Queue.snapshot(q) == before
    assert {:error, :duplicate} = Queue.admit(q, "del-20", %{})
    assert {:error, :duplicate} = Queue.admit(q, "delivery", %{})
    assert :ok = Queue.ack(q, claimed.claim_id)
    assert {:ok, records} = Queue.claim(q, 10, "other")
    refute Enum.any?(records, &(&1.key == "later"))
    assert Enum.map(records, & &1.admission) == [:delivery, :recovery]
    :atomics.put(c.clock, 1, 1_600)
    assert {:ok, [later | _]} = Queue.claim(q, 10, "after-due")
    assert later.key == "later"
  end

  test "automatic compaction permits sustained churn within the configured log bound", c do
    opts = Keyword.merge(c.opts, auto_compact: true, max_log_bytes: 4_000)
    q = start_supervised!({Queue, opts})
    assert {:ok, _} = Queue.admit(q, "live", %{v: 1})
    assert {:ok, [claimed]} = Queue.claim(q, 1, "owner")
    churn(q, 1..100)
    assert File.stat!(c.path).size <= 4_000
    [header | _] = c.path |> File.read!() |> String.split("\n", trim: true)
    assert %{"v" => 3, "type" => "retained_state"} = JSON.decode!(header)
    assert {:ok, ^claimed} = Queue.lookup(q, "live")
    stop_supervised!(Queue)
    q = start_supervised!({Queue, opts})
    assert {:ok, ^claimed} = Queue.lookup(q, "live")
    for n <- 98..100, do: assert({:error, :duplicate} = Queue.admit(q, "del-#{n}", %{}))
    assert {:ok, _} = Queue.admit(q, "del-1", %{})
    assert :ok = Queue.ack(q, claimed.claim_id)
  end

  test "full canonical state fails without replacing bytes or discarding pending work", c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.put(q, "pending", %{payload: String.duplicate("x", 800)})
    bytes = File.read!(c.path)
    before = Queue.snapshot(q)
    :sys.replace_state(q, &%{&1 | max_log_bytes: 100, auto_compact: true})
    assert {:error, {:queue_log_too_large, _, 100}} = Queue.compact(q)
    assert {:error, {:queue_log_too_large, _, 100}} = Queue.put(q, "new", %{})
    assert File.read!(c.path) == bytes
    assert Queue.snapshot(q) == before
  end

  test "default queues keep append-only history and refuse a full log", c do
    q = start_supervised!({Queue, Keyword.put(c.opts, :max_log_bytes, 500)})
    assert {:ok, _} = Queue.admit(q, "first", %{})
    assert :ok = Queue.cancel_pending(q, "first")
    bytes = File.read!(c.path)
    assert {:error, {:queue_log_too_large, _, 500}} = Queue.admit(q, "second", %{})
    assert File.read!(c.path) == bytes
    assert {:error, :duplicate} = Queue.admit(q, "first", %{})
  end

  test "record IDs do not regress after all records are completed and compacted", c do
    q = start_supervised!({Queue, c.opts})
    churn(q, 1..4)
    assert {:ok, _} = Queue.compact(q)
    churn(q, 5..8)
    stop_supervised!(Queue)
    q = start_supervised!({Queue, c.opts})
    assert {:ok, %{id: "rec-9"}} = Queue.admit(q, "new", %{})
  end

  test "an incomplete compacted prefix fails while a torn later append is repaired", c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.admit(q, "preserve", %{body: "unread"})
    assert {:ok, _} = Queue.compact(q)
    before = Queue.snapshot(q)
    stop_supervised!(Queue)
    bytes = File.read!(c.path)
    [header, _record] = String.split(bytes, "\n", trim: true)
    File.write!(c.path, header <> "\n")
    assert {:error, :invalid_retained_queue_prefix} = Queue.start_link(c.opts)
    File.write!(c.path, binary_part(bytes, 0, byte_size(bytes) - 12))
    assert {:error, :invalid_retained_queue_prefix} = Queue.start_link(c.opts)
    File.write!(c.path, bytes <> ~s({"v":1,"type":"claim"))
    q = start_supervised!({Queue, c.opts})
    assert Queue.snapshot(q) == before
    assert File.read!(c.path) == bytes
  end

  test "a repeated or foreign retained-state header fails closed", c do
    q = start_supervised!({Queue, c.opts})
    assert {:ok, _} = Queue.compact(q)
    stop_supervised!(Queue)
    bytes = File.read!(c.path)
    File.write!(c.path, bytes <> bytes)
    assert {:error, _} = Queue.start_link(c.opts)
    header = bytes |> String.trim() |> JSON.decode!() |> Map.put("queue", "foreign")
    File.write!(c.path, JSON.encode!(header) <> "\n")
    assert {:error, :bad_entry} = Queue.start_link(c.opts)
  end
end
