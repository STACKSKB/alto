defmodule Alto.RecoveryTest do
  use ExUnit.Case, async: true

  alias Alto.Consumer
  alias Alto.OperationLog
  alias Alto.Queue

  setup do
    root = Path.join(System.tmp_dir!(), "alto-recovery-#{System.unique_integer([:positive])}")
    queue_dir = Path.join(root, "queue")
    ledger_dir = Path.join(root, "ledger")
    on_exit(fn -> File.rm_rf!(root) end)
    %{queue_dir: queue_dir, ledger_dir: ledger_dir}
  end

  defp start_queue!(dir) do
    {:ok, pid} = Queue.start_link(id: "recoveryq", dir: dir, name: nil)
    pid
  end

  defp start_ledger!(dir, opts \\ []) do
    {:ok, pid} =
      OperationLog.start_link(Keyword.merge([id: "recoveryl", dir: dir, name: nil], opts))

    pid
  end

  defp start_consumer!(queue, ledger, handler) do
    {:ok, pid} =
      Consumer.start_link(
        queue: queue,
        ledger: ledger,
        handler: handler,
        autostart: false,
        name: nil
      )

    pid
  end

  test "parked recovery survives restart and confirmed success never dispatches again", context do
    queue = start_queue!(context.queue_dir)
    ledger = start_ledger!(context.ledger_dir)
    parent = self()
    consumer = start_consumer!(queue, ledger, fn _, _ -> {:park, :lost_response} end)

    {:ok, _} = Queue.admit(queue, "src:delivery-1", %{document: 7})
    assert {:handled, [:parked]} = Consumer.poll(consumer)
    assert {:ok, before} = OperationLog.recovery(ledger, "src:delivery-1")
    assert before.recovery.payload == %{document: 7}
    assert before.outcome |> elem(0) == :requires_operator

    GenServer.stop(consumer)
    GenServer.stop(queue)
    GenServer.stop(ledger)

    queue = start_queue!(context.queue_dir)
    ledger = start_ledger!(context.ledger_dir)
    assert {:ok, recovered} = OperationLog.recovery(ledger, "src:delivery-1")
    assert recovered.recovery == before.recovery

    assert {:ok, resolved} =
             OperationLog.reconcile(
               ledger,
               "src:delivery-1",
               recovered.revision,
               :confirmed_committed,
               %{participant_receipt: "receipt-7"}
             )

    assert {:decided, :completed, evidence} = OperationLog.status(ledger, "src:delivery-1")
    assert evidence.operator_resolution == :confirmed_committed
    assert resolved.revision == recovered.revision + 1

    consumer =
      start_consumer!(queue, ledger, fn _, _ ->
        send(parent, :unexpected_dispatch)
        :done
      end)

    assert :idle = Consumer.poll(consumer)
    refute_receive :unexpected_dispatch
  end

  test "retry permission is version fenced and restores the original operation", context do
    queue = start_queue!(context.queue_dir)
    ledger = start_ledger!(context.ledger_dir)
    consumer = start_consumer!(queue, ledger, fn _, _ -> {:park, :needs_lookup} end)

    {:ok, _} = Queue.admit(queue, "src:delivery-2", %{document: 8})
    assert {:handled, [:parked]} = Consumer.poll(consumer)
    {:ok, parked} = OperationLog.recovery(ledger, "src:delivery-2")

    recovery = parked.recovery

    assert {:ok, _} =
             Queue.restore(
               queue,
               parked.operation_key,
               recovery.generation_id,
               recovery.payload
             )

    assert {:ok, authorized} =
             OperationLog.reconcile(
               ledger,
               parked.operation_key,
               parked.revision,
               :retry_permitted,
               %{participant_lookup: :not_committed}
             )

    assert {:intended} = OperationLog.status(ledger, parked.operation_key)

    assert {:error, :stale_revision} =
             OperationLog.reconcile(
               ledger,
               parked.operation_key,
               parked.revision,
               :confirmed_committed,
               %{}
             )

    parent = self()

    retry_consumer =
      start_consumer!(queue, ledger, fn payload, context ->
        send(parent, {:retried, payload, context.operation_key})
        :done
      end)

    assert {:handled, [{:decided, :completed}]} = Consumer.poll(retry_consumer)
    assert_receive {:retried, %{document: 8}, "src:delivery-2"}
    assert authorized.revision == parked.revision + 1
    assert {:decided, :completed, _} = OperationLog.status(ledger, "src:delivery-2")
  end

  test "retry is refused when the accepted input was not retained", context do
    ledger = start_ledger!(context.ledger_dir)
    :ok = OperationLog.record_intent(ledger, "legacy-op", "tool", nil)
    :ok = OperationLog.record_attempt(ledger, "legacy-op", "attempt-1")
    :ok = OperationLog.record_outcome(ledger, "legacy-op", "attempt-1", :unknown)
    {:ok, item} = OperationLog.recovery(ledger, "legacy-op")

    assert {:error, :recovery_unavailable} =
             OperationLog.reconcile(
               ledger,
               "legacy-op",
               item.revision,
               :retry_permitted,
               %{}
             )
  end
end
