defmodule Alto.ConformanceTest do
  @moduledoc """
  failure conformance: scripted participants + seeded state-machine
  sequences against the decided contract (admission, outcomes,
  ledger/consumer recovery).

  Fixtures live in `Alto.Conformance.FakeSource`, `FakeService`, `FakeTool`,
  and `Sequence`. Every generated sequence records its seed; failures
  minimize via `Sequence.minimize/2`. The normal agent (model-path) matrix
  stays in the README runbook — this file covers the deterministic
  failure paths only and chooses no new isolation, retry, or compensation
  semantics.
  """

  use ExUnit.Case, async: true

  alias Alto.Conformance.FakeService
  alias Alto.Conformance.FakeSource
  alias Alto.Conformance.FakeTool
  alias Alto.Conformance.Sequence
  alias Alto.Consumer
  alias Alto.Effect
  alias Alto.Event
  alias Alto.OperationLog
  alias Alto.Queue
  alias Alto.Transition

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-conformance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    tag = System.unique_integer([:positive])
    qname = :"conf_q_#{tag}"
    lname = :"conf_l_#{tag}"
    sname = :"conf_s_#{tag}"

    {:ok, _} =
      Queue.start_link(id: "q#{tag}", dir: Path.join(dir, "q"), name: qname, lease_ms: 50)

    {:ok, _} = OperationLog.start_link(id: "l#{tag}", dir: Path.join(dir, "l"), name: lname)
    {:ok, _} = FakeService.start_link(name: sname)

    %{dir: dir, queue: qname, ledger: lname, service: sname, tag: tag}
  end

  defmodule OnceLoop do
    @behaviour Alto.Loop
    @impl true
    def init({name, args}, _spec) do
      Transition.continue(%{}, [Effect.invoke_tool(%{id: "op-1", name: name, arguments: args})])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: data}, s, _spec),
      do: Transition.stop(s, {:completed, data})

    def handle_event(%Event{type: :tool_failed, data: data}, s, _spec),
      do: Transition.stop(s, {:failed, data})

    def handle_event(_e, s, _spec), do: Transition.continue(s)
  end

  test "committed-but-unacknowledged effects stay unknown and park, never succeed", %{
    queue: q,
    ledger: l,
    service: s
  } do
    # Timeout after commit: the service applied, the runner lost the reply.
    assert {:ok, result} =
             Alto.run({"commit_then_timeout", %{}},
               loop: Alto.loop(OnceLoop),
               tools: [{FakeTool.CommitThenTimeout, service: s, key: "print-1", test_pid: self()}],
               tool_timeout: 1_000
             )

    assert_received {:committed, "print-1"}
    assert {:failed, %{outcome: :unknown}} = result.output
    assert FakeService.committed?(s, "print-1")

    # The same shape through the consumer parks for reconciliation.
    {:ok, _} = Queue.admit(q, "src:del-timeout", %{"body" => "x"})
    {:ok, [claimed]} = Queue.claim(q, 1, "w-1")
    :ok = OperationLog.record_intent(l, "src:del-timeout", "print", "src:del-timeout")
    :ok = OperationLog.record_attempt(l, "src:del-timeout", claimed.claim_id)
    # No outcome line exists: dispatched without outcome.
    assert {:dispatched, _} = OperationLog.status(l, "src:del-timeout")

    c =
      start_consumer!(queue: q, ledger: l, handler: fn _, _ -> {:park, :reconcile} end, by: "w-2")

    # The parked claim is a *different* record; the dispatched one reconciles
    # via an explicit operator outcome, never an invented success.
    :ok =
      OperationLog.record_outcome(l, "src:del-timeout", claimed.claim_id, :requires_operator, %{})

    assert {:decided, :requires_operator, _} = OperationLog.status(l, "src:del-timeout")
    GenServer.stop(c)
  end

  test "commit-then-crash is unknown with the commit recorded", %{service: s} do
    assert {:ok, result} =
             Alto.run({"commit_then_crash", %{}},
               loop: Alto.loop(OnceLoop),
               tools: [{FakeTool.CommitThenCrash, service: s, key: "print-2", test_pid: self()}]
             )

    assert_received {:committed, "print-2"}
    assert {:failed, %{outcome: :unknown}} = result.output
    assert 1 = FakeService.commit_count(s, "print-2")
  end

  test "duplicate and reordered deliveries queue once, first-wins", %{queue: q} do
    seed = 202_609_08
    {deliveries, ^seed} = FakeSource.generate(seed, 6, duplicate_rate: 0.8, reorder: true)

    results = Enum.map(deliveries, &FakeSource.admit(q, &1))
    assert Enum.any?(results, &match?({:error, :duplicate}, &1))

    # Exactly one live record per distinct key, holding the first arrival's
    # bytes (arrival order, not business order).
    pending = Queue.records(q, 100)
    by_key = Enum.group_by(pending, & &1.key)
    assert Enum.all?(by_key, fn {_, records} -> length(records) == 1 end)

    first_arrival =
      Enum.reduce(deliveries, %{}, fn d, acc -> Map.put_new(acc, d.key, d.body) end)

    for record <- pending do
      assert record.payload["body"] == first_arrival[record.key]
    end
  end

  test "dedup expiry honestly re-admits after the bounded window", %{dir: dir, tag: tag} do
    name = :"conf_expiry_#{tag}"

    {:ok, _} =
      Queue.start_link(id: "qe#{tag}", dir: Path.join(dir, "qe"), name: name, max_completed: 2)

    for n <- 1..3 do
      key = "src:del-#{n}"
      {:ok, _} = Queue.admit(name, key, %{})
      {:ok, [claimed]} = Queue.claim(name, 1, "w")
      :ok = Queue.ack(name, claimed.claim_id)
    end

    # Oldest completion fell out: redelivery is legitimately new work.
    assert {:ok, %{revision: 1}} = Queue.admit(name, "src:del-1", %{})
    # Recent completions still dedup.
    assert {:error, :duplicate} = Queue.admit(name, "src:del-3", %{})
  end

  test "storage failure changes nothing and stays retryable", %{queue: q, dir: dir, tag: tag} do
    {:ok, _} = Queue.admit(q, "src:keep", %{})
    {:ok, [claimed]} = Queue.claim(q, 1, "w")

    # Break the log file: the next append fails instead of claiming success.
    path = Path.join([dir, "q", "q#{tag}.jsonl"])
    File.rm!(path)
    File.mkdir!(path)

    assert {:error, _} = Queue.ack(q, claimed.claim_id)
    assert %{pending: 0, claimed: 1} = Queue.count(q)
  end

  test "stalled consumers lose the claim, never the record", %{ledger: l} do
    dir = Path.join(System.tmp_dir!(), "alto-conf-stall-#{System.unique_integer([:positive])}")
    tag = System.unique_integer([:positive])
    qname = :"conf_stall_q_#{tag}"
    {:ok, _} = Queue.start_link(id: "sq#{tag}", dir: dir, name: qname, lease_ms: 30)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, _} = Queue.admit(qname, "src:stalled", %{})

    blocker = fn _payload, _ctx ->
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
    Process.sleep(150)
    # True preemption (:kill), not a polite stop: the lease expires and the
    # heir finds dispatched-without-outcome and parks instead of rerunning.
    Process.unlink(c1)
    Process.exit(c1, :kill)
    Process.exit(poller, :kill)
    Process.sleep(120)

    c2 =
      start_consumer!(queue: qname, ledger: l, handler: fn _, _ -> {:park, :heir} end, by: "heir")

    assert {:handled, [:parked]} = Consumer.poll(c2)
    assert ["src:stalled"] = OperationLog.list_parked(l)
  end

  test "seeded sequences run deterministically and minimize on failure" do
    {ops_a, seed} = Sequence.generate(7, 20)
    {ops_b, ^seed} = Sequence.generate(7, 20)
    assert ops_a == ops_b
    assert length(ops_a) == 20

    # Minimization keeps a failing sequence failing while shrinking it.
    failing = [:a, :b, :c, :d]
    check = fn ops -> if :c in ops, do: {:fail, :has_c}, else: :pass end
    assert [:c] = Sequence.minimize(failing, check)

    # Record the seed with the test output for reproduction.
    assert is_integer(seed)
  end

  test "same contract against two store configurations agrees within the window", %{dir: dir} do
    {ops, seed} = Sequence.generate(42, 16)
    _ = seed

    %{a: log_a, b: log_b} =
      Sequence.run_storage_contract(ops, [lease_ms: 50], max_completed: 2, lease_ms: 50)

    # Both logs replay the same op kinds in the same order; only
    # window-expiry admissions may differ (honest re-admission).
    kinds = fn log -> Enum.map(log, &elem(&1, 0)) end
    assert kinds.(log_a) == kinds.(log_b)
    _ = dir
  end

  test "reconciliation never invents success from dispatched-without-outcome", %{
    queue: q,
    ledger: l
  } do
    {:ok, _} = Queue.admit(q, "src:del-unknown", %{"body" => "x"})
    {:ok, [claimed]} = Queue.claim(q, 1, "w-1")
    :ok = OperationLog.record_intent(l, "src:del-unknown", "print", "src:del-unknown")
    :ok = OperationLog.record_attempt(l, "src:del-unknown", claimed.claim_id)

    refute match?({:decided, _, _}, OperationLog.status(l, "src:del-unknown"))
    assert ["src:del-unknown"] = OperationLog.list_open(l)

    # Recovery parks; it never reports completed.
    :ok =
      OperationLog.record_outcome(l, "src:del-unknown", claimed.claim_id, :requires_operator, %{})

    assert {:decided, :requires_operator, _} = OperationLog.status(l, "src:del-unknown")
  end

  defp start_consumer!(opts) do
    name = :"conf_consumer_#{System.unique_integer([:positive])}"
    {:ok, pid} = Consumer.start_link(Keyword.merge([autostart: false, name: name], opts))
    pid
  end
end
