defmodule Alto.ConformanceTest do
  @moduledoc """
  Failure conformance for scripted participants at the execution boundary.

  Fixtures live in `Alto.Conformance.FakeService` and `FakeTool`.
  """

  use ExUnit.Case, async: true

  alias Alto.Conformance.FakeService
  alias Alto.Conformance.FakeTool

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  setup do
    tag = System.unique_integer([:positive])
    sname = :"conf_s_#{tag}"
    {:ok, _} = FakeService.start_link(name: sname)

    %{service: sname}
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
end
