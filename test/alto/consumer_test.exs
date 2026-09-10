defmodule Alto.ConsumerTest do
  @moduledoc """
  conformance: the bounded durable inbox consumer.

  Claim → short run → outcome handling → ack or park, with `claim_id`
  fencing, safe lease expiry, ledger-counted attempts, and workers that
  never block the registry. Unknown outcomes park before any repeat;
  decided outcomes ack without re-running.
  """

  use ExUnit.Case, async: true

  alias Alto.Consumer
  alias Alto.OperationLog
  alias Alto.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-consumer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    tag = System.unique_integer([:positive])
    qname = :"consumer_queue_#{tag}"
    lname = :"consumer_ledger_#{tag}"

    {:ok, _} = Queue.start_link(id: "q#{tag}", dir: Path.join(dir, "q"), name: qname)
    {:ok, _} = OperationLog.start_link(id: "l#{tag}", dir: Path.join(dir, "l"), name: lname)

    %{dir: dir, queue: qname, ledger: lname}
  end

  defp start_consumer!(opts) do
    name = :"consumer_#{System.unique_integer([:positive])}"
    {:ok, pid} = Consumer.start_link(Keyword.merge([autostart: false, name: name], opts))
    pid
  end

  defp done_handler(test_pid \\ nil) do
    fn _payload, _ctx ->
      if test_pid, do: send(test_pid, :handled)
      :done
    end
  end

  test "accepted work completes: claim, run, ack", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:del-1", %{"body" => "x"})
    c = start_consumer!(queue: q, ledger: l, handler: done_handler(self()), by: "w-1")

    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c)
    assert_received :handled

    assert %{pending: 0, claimed: 0} = Queue.count(q)
    assert {:decided, :completed, _} = OperationLog.status(l, "src:del-1")
  end

  test "retry releases with a counted attempt, then completes", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:del-1", %{})
    test_pid = self()

    handler = fn _payload, _ctx ->
      send(test_pid, :ran)

      receive do
        :allow_done -> :done
      after
        0 -> {:retry, :downstream_busy}
      end
    end

    c = start_consumer!(queue: q, ledger: l, handler: handler, by: "w-1")

    assert {:handled, [:released]} = Consumer.poll(c)
    assert %{pending: 1, claimed: 0} = Queue.count(q)
    assert 1 = OperationLog.attempts(l, "src:del-1")

    # Second poll retries under the same identity.
    assert {:handled, [:released]} = Consumer.poll(c)
    assert 2 = OperationLog.attempts(l, "src:del-1")
  end

  test "attempts beyond the bound park for an operator", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:del-1", %{})

    c =
      start_consumer!(
        queue: q,
        ledger: l,
        handler: fn _, _ -> {:retry, :busy} end,
        max_attempts: 2,
        by: "w-1"
      )

    assert {:handled, [:released]} = Consumer.poll(c)
    assert {:handled, [:released]} = Consumer.poll(c)
    assert {:handled, [:parked]} = Consumer.poll(c)

    assert ["src:del-1"] = OperationLog.list_parked(l)
    assert %{pending: 0, claimed: 0} = Queue.count(q)
    assert {:decided, :requires_operator, _} = OperationLog.status(l, "src:del-1")
  end

  test "unknown short-run outcomes park before any repeat", %{queue: q, ledger: l} do
    defmodule SleepyTool do
      @behaviour Alto.Tool
      @impl true
      def name, do: :sleepy
      @impl true
      def schema, do: %{parameters: %{type: "object", properties: %{}}}
      @impl true
      def execution_mode, do: :exclusive
      @impl true
      def approval, do: :never
      @impl true
      def run(_args, _ctx) do
        Process.sleep(5_000)
        {:ok, :unreachable}
      end
    end

    defmodule UnknownLoop do
      @behaviour Alto.Loop
      @impl true
      def init(_task, _spec) do
        Alto.Transition.continue(%{}, [
          Alto.Effect.invoke_tool(%{id: "t-1", name: "sleepy", arguments: %{}})
        ])
      end

      @impl true
      def handle_event(%Alto.Event{type: type, data: _data} = event, s, _spec)
          when type in [:tool_completed, :tool_failed] do
        Alto.Transition.stop(s, event)
      end

      def handle_event(_e, s, _spec), do: Alto.Transition.continue(s)
    end

    {:ok, _} = Queue.admit(q, "src:del-1", %{})

    handler = fn _payload, _ctx ->
      {:ok, result} =
        Alto.run("go",
          loop: Alto.loop(UnknownLoop),
          tools: [SleepyTool],
          tool_timeout: 50
        )

      case Consumer.worst_outcome(result.events) do
        :unknown -> {:park, :unknown_tool_outcome}
        :failed -> {:failed, :known}
        :completed -> :done
        :empty -> {:failed, :no_tools_ran}
      end
    end

    c = start_consumer!(queue: q, ledger: l, handler: handler, by: "w-1")
    assert {:handled, [:parked]} = Consumer.poll(c)

    # Parked on first sight: the effect ran once, never twice.
    assert ["src:del-1"] = OperationLog.list_parked(l)
    assert %{pending: 0, claimed: 0} = Queue.count(q)
  end

  test "a stale worker cannot ack a newer owner's claim", %{queue: q, ledger: l} do
    # Short lease, slow handler: the ack lands after expiry.
    dir = Path.join(System.tmp_dir!(), "alto-stale-#{System.unique_integer([:positive])}")
    tag = System.unique_integer([:positive])
    q2 = :"stale_queue_#{tag}"
    {:ok, _} = Queue.start_link(id: "sq#{tag}", dir: dir, name: q2, lease_ms: 30)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, _} = Queue.admit(q2, "src:del-1", %{})
    test_pid = self()

    slow = fn _payload, _ctx ->
      Process.sleep(150)
      send(test_pid, :slow_ran)
      :done
    end

    c1 = start_consumer!(queue: q2, ledger: l, handler: slow, by: "slow", handle_timeout: 5_000)
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c1)
    assert_received :slow_ran

    # The lease expired mid-work: the ack failed, the work is still live.
    assert %{pending: 1, claimed: 0} = Queue.count(q2)

    # The next owner reconciles through the ledger: decided, so ack only.
    c2 = start_consumer!(queue: q2, ledger: l, handler: done_handler(self()), by: "fast")
    assert {:handled, [:acked_decided]} = Consumer.poll(c2)
    assert %{pending: 0, claimed: 0} = Queue.count(q2)

    # The effect ran exactly once across both owners.
    refute_received :slow_ran
    refute_received :handled
    _ = q
  end

  test "two workers split work without double-handling", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:a", %{})
    {:ok, _} = Queue.admit(q, "src:b", %{})

    test_pid = self()

    handler = fn _payload, %{claim_id: claim_id} ->
      send(test_pid, {:ran, claim_id})
      :done
    end

    a = start_consumer!(queue: q, ledger: l, handler: handler, by: "a")
    b = start_consumer!(queue: q, ledger: l, handler: handler, by: "b")

    assert {:handled, _} = Consumer.poll(a)
    assert {:handled, _} = Consumer.poll(b)

    assert_received {:ran, claim_a}
    assert_received {:ran, claim_b}
    assert claim_a != claim_b
    assert %{pending: 0, claimed: 0} = Queue.count(q)
    assert [] = OperationLog.list_open(l)
  end

  test "duplicate deliveries reach the consumer once", %{queue: q, ledger: l} do
    assert {:ok, _} = Queue.admit(q, "src:del-1", %{})
    assert {:error, :duplicate} = Queue.admit(q, "src:del-1", %{})

    c = start_consumer!(queue: q, ledger: l, handler: done_handler(self()), by: "w-1")
    assert {:handled, _} = Consumer.poll(c)
    assert_received :handled

    assert {:error, :duplicate} = Queue.admit(q, "src:del-1", %{})
    assert :idle = Consumer.poll(c)
    refute_received :handled
  end

  test "checkpointed work is acknowledged after restart without handler replay", %{dir: dir} do
    tag = System.unique_integer([:positive])
    qname = String.to_atom("checkpoint_queue_#{tag}")
    lname = String.to_atom("checkpoint_ledger_#{tag}")
    qdir = Path.join(dir, "cq")
    ldir = Path.join(dir, "cl")
    {:ok, _} = Queue.start_link(id: "cq#{tag}", dir: qdir, name: qname)
    {:ok, _} = OperationLog.start_link(id: "cl#{tag}", dir: ldir, name: lname)
    {:ok, _} = Queue.put(qname, "job", %{value: 1})
    {:ok, record} = Queue.lookup(qname, "job")
    parent = self()

    c =
      start_consumer!(
        queue: qname,
        ledger: lname,
        handler: fn _, _ ->
          send(parent, :checkpoint_ran)
          {:checkpoint, %{"state" => 1}}
        end
      )

    assert {:handled, [:checkpointed]} = Consumer.poll(c)
    assert_received :checkpoint_ran
    GenServer.stop(c)
    GenServer.stop(qname)
    GenServer.stop(lname)
    {:ok, _} = Queue.start_link(id: "cq#{tag}", dir: qdir, name: qname)
    {:ok, _} = OperationLog.start_link(id: "cl#{tag}", dir: ldir, name: lname)

    {:ok, _} =
      Queue.restore(
        qname,
        "business-generation:" <> record.generation_id,
        record.generation_id,
        %{value: 1},
        recovery_revision: 3
      )

    {:ok, _} = Queue.put(qname, "independent", %{value: 2})

    c2 =
      start_consumer!(
        queue: qname,
        ledger: lname,
        handler: fn payload, _ ->
          send(parent, {:ran, payload})
          :done
        end
      )

    assert {:handled, [:acked_checkpoint]} = Consumer.poll(c2)
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c2)
    assert_received {:ran, %{value: 2}}
    refute_received :ran
  end

  test "a business key gets a fresh ledger identity after completion", %{queue: q, ledger: l} do
    test_pid = self()

    handler = fn payload, _ctx ->
      send(test_pid, {:handled_payload, payload})
      :done
    end

    c = start_consumer!(queue: q, ledger: l, handler: handler, by: "w-1")
    {:ok, _} = Queue.put(q, "job-1", %{version: 1})
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c)
    assert_received {:handled_payload, %{version: 1}}

    {:ok, _} = Queue.put(q, "job-1", %{version: 2})
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c)
    assert_received {:handled_payload, %{version: 2}}
  end

  test "handler context separates business and operation identity", %{queue: q, ledger: l} do
    parent = self()

    handler = fn _payload, context ->
      send(parent, {:context, context})
      :done
    end

    c = start_consumer!(queue: q, ledger: l, handler: handler, by: "w-1")
    {:ok, _} = Queue.put(q, "customer-42", %{version: 1})
    assert {:handled, [{:decided, :completed}]} = Consumer.poll(c)
    assert_receive {:context, context}
    assert context.key == context.operation_key
    assert context.operation_key =~ "business-generation:gen-"
    refute context.operation_key == "customer-42"
  end

  test "a dead queue fails the poll while the worker survives", %{queue: q, ledger: l} do
    pid = Process.whereis(q)
    GenServer.stop(pid)

    c = start_consumer!(queue: q, ledger: l, handler: done_handler(), by: "w-1")
    assert {:error, {:queue_unavailable, _}} = Consumer.poll(c)
    assert Process.alive?(c)
  end

  test "a dead worker's lease hands parked work to the next owner", %{ledger: l} do
    dir = Path.join(System.tmp_dir!(), "alto-crash-#{System.unique_integer([:positive])}")
    tag = System.unique_integer([:positive])
    qname = :"crash_queue_#{tag}"
    {:ok, _} = Queue.start_link(id: "cq#{tag}", dir: dir, name: qname, lease_ms: 30)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, _} = Queue.admit(qname, "src:del-1", %{})
    test_pid = self()

    blocker = fn _payload, _ctx ->
      send(test_pid, :work_started)
      Process.sleep(5_000)
      :done
    end

    c1 =
      start_consumer!(
        queue: qname,
        ledger: l,
        handler: blocker,
        by: "doomed",
        handle_timeout: 10_000
      )

    poller = spawn(fn -> Consumer.poll(c1) end)
    assert_receive :work_started, 2_000
    # A true crash: unlike GenServer.stop/3 (which politely waits out the
    # in-flight call), :kill preempts it mid-dispatch.
    Process.unlink(c1)
    Process.exit(c1, :kill)
    Process.exit(poller, :kill)

    # The lease expires; the next owner finds dispatched-without-outcome
    # and parks instead of re-running.
    Process.sleep(100)
    c2 = start_consumer!(queue: qname, ledger: l, handler: done_handler(self()), by: "heir")
    assert {:handled, [:parked]} = Consumer.poll(c2)

    assert ["src:del-1"] = OperationLog.list_parked(l)
    refute_received :handled
  end

  test "a crashing handler parks the work and spares the worker", %{queue: q, ledger: l} do
    {:ok, _} = Queue.admit(q, "src:del-1", %{})

    c =
      start_consumer!(queue: q, ledger: l, handler: fn _, _ -> raise "handler bug" end, by: "w-1")

    assert {:handled, [:parked]} = Consumer.poll(c)
    assert Process.alive?(c)
    assert ["src:del-1"] = OperationLog.list_parked(l)
  end

  test "worst_outcome folds tool events" do
    completed = %Alto.Event{
      domain: :durable,
      type: :tool_completed,
      data: %{outcome: :completed},
      at_ms: 0,
      seq: nil
    }

    failed = %Alto.Event{
      domain: :durable,
      type: :tool_failed,
      data: %{outcome: :failed_known},
      at_ms: 0,
      seq: nil
    }

    unknown = %Alto.Event{
      domain: :durable,
      type: :tool_failed,
      data: %{outcome: :unknown},
      at_ms: 0,
      seq: nil
    }

    other = %Alto.Event{domain: :durable, type: :step_settled, data: %{}, at_ms: 0, seq: nil}

    assert :empty = Consumer.worst_outcome([])
    assert :empty = Consumer.worst_outcome([other])
    assert :completed = Consumer.worst_outcome([completed])
    assert :failed = Consumer.worst_outcome([completed, failed])
    assert :unknown = Consumer.worst_outcome([failed, unknown, completed])

    cancelled =
      %Alto.Event{
        domain: :durable,
        type: :run_cancelled,
        data: %{in_flight: %{operation_id: "op", outcome: :unknown}},
        at_ms: 0,
        seq: nil
      }

    assert :unknown = Consumer.worst_outcome([completed, cancelled])
  end

  test "authoritative run verdict survives bounded event eviction" do
    result = %Alto.Runner.Serial.Result{
      output: nil,
      loop_state: nil,
      messages: [],
      events: [],
      events_dropped: 20,
      verdict: :unknown,
      model_requests: 0,
      transcript_bytes: 0,
      session_id: nil,
      run_id: "run-authoritative"
    }

    assert :unknown = Consumer.worst_outcome(result)
  end

  test "consumer persists an authoritative unknown run verdict", %{queue: q, ledger: l} do
    result = %Alto.Runner.Serial.Result{
      output: nil,
      loop_state: nil,
      messages: [],
      events: [],
      events_dropped: 50,
      verdict: :unknown,
      model_requests: 0,
      transcript_bytes: 0,
      session_id: nil,
      run_id: "run-unknown"
    }

    {:ok, _} = Queue.admit(q, "src:unknown", %{})
    c = start_consumer!(queue: q, ledger: l, handler: fn _, _ -> {:run, result} end)

    assert {:handled, [{:decided, :unknown}]} = Consumer.poll(c)
    assert {:decided, :unknown, evidence} = OperationLog.status(l, "src:unknown")
    assert evidence.run_id == "run-unknown"
    assert %{pending: 0, claimed: 0} = Queue.count(q)
  end
end
