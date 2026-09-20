defmodule Alto.ConformanceTest do
  @moduledoc """
  failure conformance: scripted participants + seeded state-machine
  sequences against the decided contract (admission, outcomes,
  ledger/consumer recovery).

  Fixtures live in `Alto.Conformance.FakeService`, `FakeTool`, and `Sequence`.
  Every generated sequence records its seed; failures
  minimize via `Sequence.minimize/2`. The normal agent (model-path) matrix
  stays in the README runbook — this file covers the deterministic
  failure paths only and chooses no new isolation, retry, or compensation
  semantics.
  """

  use ExUnit.Case, async: true

  alias Alto.Conformance.FakeService
  alias Alto.Conformance.FakeTool
  alias Alto.Conformance.Sequence

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-conformance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    tag = System.unique_integer([:positive])
    sname = :"conf_s_#{tag}"
    {:ok, _} = FakeService.start_link(name: sname)

    %{dir: dir, service: sname}
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

  test "committed-but-unacknowledged effects stay unknown", %{service: s} do
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
end
