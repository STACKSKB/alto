defmodule Alto.Integration.DurableWorkTest do
  use ExUnit.Case, async: true
  alias Alto.{Consumer, OperationLog, Queue}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 10_000)

    opts = [
      id: "queue",
      dir: Path.join(dir, "queue"),
      name: nil,
      lease_ms: 100,
      clock: fn -> :atomics.get(clock, 1) end
    ]

    queue = start_supervised!({Queue, opts})

    ledger =
      start_supervised!({OperationLog, id: "ledger", dir: Path.join(dir, "ledger"), name: nil})

    %{queue: queue, ledger: ledger, opts: opts, clock: clock}
  end

  test "updates, scheduling, lease fencing, cancellation and deduplication survive queue restart",
       c do
    assert {:ok, first} = Queue.request(c.queue, {:put, "work", %{version: 1}, []})
    assert {:ok, first_view} = Queue.request(c.queue, {:lookup, "work"})
    assert {:ok, updated} = Queue.request(c.queue, {:put, "work", %{version: 2}, []})
    assert updated.id == first.id
    assert updated.revision > first.revision
    assert {:ok, _} = Queue.request(c.queue, {:admit, "delivery", %{version: 1}, [delay_ms: 300]})
    assert {:error, :duplicate} = Queue.request(c.queue, {:admit, "delivery", %{version: 2}, []})
    assert {:ok, [claimed]} = Queue.request(c.queue, {:claim, 2, "first", :infinity, :all})
    assert claimed.key == "work"
    assert claimed.payload == %{version: 2}
    assert {:error, {:key_claimed, "work"}} = Queue.request(c.queue, {:put, "work", %{}, []})
    assert {:error, {:key_claimed, "work"}} = Queue.request(c.queue, {:cancel_pending, "work"})
    :atomics.put(c.clock, 1, 10_100)
    assert {:ok, [reclaimed]} = Queue.request(c.queue, {:claim, 1, "second", :infinity, :all})
    assert reclaimed.claim_id != claimed.claim_id
    assert {:error, :not_found} = Queue.request(c.queue, {:settle, claimed.claim_id, :ack, []})
    assert :ok = Queue.request(c.queue, {:settle, reclaimed.claim_id, :release, []})
    assert :ok = Queue.request(c.queue, {:cancel_pending, "work"})
    stop_supervised!(Queue)
    queue = start_supervised!({Queue, c.opts})
    assert {:ok, []} = Queue.request(queue, {:claim, 2, nil, :infinity, :all})
    :atomics.put(c.clock, 1, 10_300)

    assert {:ok, [%{key: "delivery", payload: %{version: 1}} = delivery]} =
             Queue.request(queue, {:claim, 2, nil, :infinity, :all})

    assert :ok = Queue.request(queue, {:settle, delivery.claim_id, :ack, []})
    assert {:error, :duplicate} = Queue.request(queue, {:admit, "delivery", %{}, []})
    assert %{pending: 0, claimed: 0} = Queue.request(queue, :count)
    assert {:ok, _replacement} = Queue.request(queue, {:put, "work", %{version: 3}, []})
    assert {:ok, replacement} = Queue.request(queue, {:lookup, "work"})
    assert replacement.generation_id != first_view.generation_id
  end

  test "the consumer retries under one identity, completes once and parks exhausted generations",
       c do
    owner = self()

    handler = fn payload, context ->
      send(owner, {:handled, payload, context})
      if payload[:park] || context.attempt == 1, do: :retry, else: {:outcome, :completed, %{}}
    end

    consumer =
      start_supervised!(
        {Consumer,
         queue: c.queue,
         ledger: c.ledger,
         handler: handler,
         name: nil,
         autostart: false,
         max_attempts: 2}
      )

    assert {:ok, _} = Queue.request(c.queue, {:put, "business", %{version: 1}, []})
    assert {:handled, [:released]} = Consumer.poll(consumer)
    assert_receive {:handled, %{version: 1}, first}
    assert first.operation_key != "business"
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(consumer)
    assert_receive {:handled, %{version: 1}, second}
    assert first.operation_key == second.operation_key
    assert second.attempt == 2
    assert :idle = Consumer.poll(consumer)
    refute_received {:handled, _, _}
    assert {:ok, _} = Queue.request(c.queue, {:put, "business", %{park: true}, []})
    assert {:handled, [:released]} = Consumer.poll(consumer)
    assert_receive {:handled, %{park: true}, replacement}
    assert replacement.operation_key != first.operation_key
    assert {:handled, [:released]} = Consumer.poll(consumer)
    assert_receive {:handled, %{park: true}, _}
    assert {:handled, [:parked]} = Consumer.poll(consumer)
    refute_received {:handled, _, _}

    assert {:decided, :requires_operator, _} =
             OperationLog.request(c.ledger, {:status, replacement.operation_key})

    assert %{pending: 0, claimed: 0} = Queue.request(c.queue, :count)
  end
end
