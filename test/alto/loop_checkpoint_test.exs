defmodule Alto.LoopCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.Loops.Default
  alias Alto.Loops.Rule

  test "default loop uses the current spec after loading state" do
    spec = Alto.loop(Default, context: %{window: 1}, subagents: %{depth: 2})
    state = %Default{task: "task", phase: :awaiting_model, step: 4}

    assert {:ok, restored} = Default.load_checkpoint(state, spec)

    assert {:continue, _, [{:request_model, %{context: %{window: 1}}}]} =
             Default.handle_event(
               Alto.Event.live(:input_received, %{text: "next"}),
               restored,
               spec
             )
  end

  test "a restored rule ignores other calls and advances with prior native results" do
    spec =
      Alto.rule_loop(
        steps: [
          "one",
          %{tool: "two", arguments: fn task, [first] -> Map.put(task, :first, first) end}
        ]
      )

    {:continue, state, [_]} = Rule.init(%{input: 7}, spec)
    {:ok, checkpoint} = Rule.dump_checkpoint(state, spec)
    {:ok, restored} = Rule.load_checkpoint(checkpoint, spec)

    for type <- [:tool_completed, :tool_failed] do
      assert {:continue, ^restored, []} =
               Rule.handle_event(Alto.Event.live(type, %{call_id: "other"}), restored, spec)
    end

    assert {:continue, next,
            [
              {:invoke_tool,
               %{id: "rule-2", name: "two", arguments: %{input: 7, first: {:native, 3}}}}
            ]} =
             Rule.handle_event(
               Alto.Event.live(:tool_completed, %{call_id: "rule-1", value: {:native, 3}}),
               restored,
               spec
             )

    assert {{:stop, [{:native, 3}, :done]}, _, []} =
             Rule.handle_event(
               Alto.Event.live(:tool_completed, %{call_id: "rule-2", value: :done}),
               next,
               spec
             )
  end

  test "rule checkpoint rejects invalid indices and malformed shapes" do
    spec = Alto.rule_loop(steps: ["one", "two"])

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint({3, %{}, []}, spec)

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint({1, [], []}, spec)
  end
end
