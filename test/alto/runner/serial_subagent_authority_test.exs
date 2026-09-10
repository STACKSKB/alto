defmodule Alto.Runner.SerialSubagentAuthorityTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule ParentLoop do
    @behaviour Alto.Loop
    def init(%{spawn: spawn}, _), do: Transition.continue(%{}, [Effect.spawn_agent(spawn)])

    def handle_event(%Event{type: type, data: data}, state, _)
        when type in [:subagent_completed, :subagent_failed],
        do: Transition.stop(state, data)

    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule BatchParentLoop do
    @behaviour Alto.Loop
    def init(%{spawns: spawns}, _),
      do: Transition.continue(%{}, [Effect.spawn_agents(%{agents: spawns})])

    def handle_event(%Event{type: :subagents_completed, data: data}, state, _),
      do: Transition.stop(state, {:completed, data})

    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule SpawnLoop do
    @behaviour Alto.Loop
    def init(%{spawn: spawn}, _), do: Transition.continue(%{}, [Effect.spawn_agent(spawn)])

    def handle_event(%Event{type: type, data: data}, state, _)
        when type in [:subagent_completed, :subagent_failed],
        do: Transition.stop(state, data)

    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule NativeLoop do
    @behaviour Alto.Loop
    def init(%{name: name}, _),
      do:
        Transition.continue(%{}, [
          Effect.invoke_tool(%{id: "native", name: to_string(name), arguments: %{}})
        ])

    def handle_event(%Event{type: type, data: data}, state, _)
        when type in [:tool_completed, :tool_failed],
        do: Transition.stop(state, data)

    def handle_event(_, state, _), do: Transition.continue(state)
  end

  defmodule SafeTool do
    @behaviour Alto.Tool
    def name, do: :safe
    def schema, do: %{description: "safe", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_, _context), do: {:ok, :safe}
  end

  defmodule ExtraTool do
    @behaviour Alto.Tool
    def name, do: :extra
    def schema, do: %{description: "extra", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_, _context), do: raise("extra tool dispatched")
  end

  defmodule ReplacementSafeTool do
    @behaviour Alto.Tool
    def name, do: :safe
    def schema, do: SafeTool.schema()
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_, _context), do: raise("replacement tool dispatched")
  end

  defmodule UnknownTool do
    @behaviour Alto.Tool
    def name, do: :unknown_tool
    def schema, do: %{description: "unknown", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_, _), do: {:unknown, :transport_lost}
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:provider_started, self()})
      receive do: (:never -> {:ok, %{message: "done", tool_calls: []}})
    end
  end

  defmodule UsageProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      usage = Keyword.fetch!(opts, :usage)
      {:ok, %{message: "done", tool_calls: [], usage: usage}}
    end
  end

  defmodule MarkProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), :grandchild_provider_called)
      {:ok, %{message: "grandchild", tool_calls: []}}
    end
  end

  defp parent_loop(depth, driver \\ ParentLoop),
    do: Alto.loop(driver, subagents: Alto.Subagents.bounded(max_depth: depth))

  test "child tools are an exact normalized subset and cannot add or replace capabilities" do
    for child_tools <- [[ExtraTool], [ReplacementSafeTool], [{SafeTool, []}]] do
      request = %{
        id: "child",
        task: %{name: :safe},
        tools: child_tools,
        loop: Alto.loop(NativeLoop)
      }

      assert {:ok, result} =
               Alto.run(
                 %{spawn: request},
                 loop: parent_loop(1),
                 tools: [SafeTool]
               )

      case child_tools do
        [{SafeTool, []}] ->
          assert result.output.output.value == :safe

        _ ->
          assert result.output.error == :tool_scope_exceeded
      end
    end
  end

  test "killing a parent tears down a blocking child" do
    owner = self()

    {:ok, handle} =
      Alto.start(
        %{spawn: %{id: "child", task: "block", provider: {BlockingProvider, owner: owner}}},
        loop: parent_loop(1),
        provider: {BlockingProvider, owner: owner}
      )

    assert_receive {:provider_started, parent_or_child}, 2_000
    child_monitor = Process.monitor(parent_or_child)
    Process.exit(handle.task.pid, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, ^parent_or_child, _}, 2_000
  end

  test "child cannot widen inherited depth by requesting a deeper policy" do
    owner = self()
    grandchild = %{id: "grand", task: "must not run", provider: {MarkProvider, owner: owner}}
    child_loop = Alto.loop(SpawnLoop, subagents: Alto.Subagents.bounded(max_depth: 100))

    assert {:ok, result} =
             Alto.run(
               %{spawn: %{id: "child", task: %{spawn: grandchild}, loop: child_loop}},
               loop: parent_loop(1),
               provider: {UsageProvider, usage: %{}}
             )

    refute_received :grandchild_provider_called
    assert result.output.output.error == :max_depth_exceeded
  end

  test "unknown child tool outcome makes the parent verdict unknown" do
    assert {:ok, result} =
             Alto.run(
               %{
                 spawn: %{id: "child", task: %{name: :unknown_tool}, loop: Alto.loop(NativeLoop)}
               },
               loop: parent_loop(1),
               tools: [UnknownTool]
             )

    assert result.verdict == :unknown
  end

  test "descendant usage is included for single and batch delegation" do
    one = %{
      id: "one",
      task: "one",
      provider: {UsageProvider, usage: %{"input_tokens" => 2, "output_tokens" => 3}}
    }

    two = %{
      id: "two",
      task: "two",
      provider: {UsageProvider, usage: %{"input_tokens" => 5, "output_tokens" => 7}}
    }

    assert {:ok, single} = Alto.run(%{spawn: one}, loop: parent_loop(1))
    assert single.usage.input_tokens == 2
    assert single.usage.output_tokens == 3

    assert {:ok, batch} = Alto.run(%{spawns: [one, two]}, loop: parent_loop(1, BatchParentLoop))
    assert batch.usage.input_tokens == 7
    assert batch.usage.output_tokens == 10
  end
end
