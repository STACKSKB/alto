defmodule Alto.LoopCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.Loop.Spec
  alias Alto.Loops.{Default, Rule}

  test "default loop uses the current spec after loading state" do
    spec = Spec.new(Default, context: %{window: 1}, subagents: %{depth: 2})
    state = %Default{task: "task", phase: :awaiting_model, step: 4}

    assert {:ok, restored} = Default.load_checkpoint(state, spec)

    assert {:continue, _, [{:request_model, %{context: %{window: 1}}}]} =
             Default.handle_event(
               Alto.Event.live(:input_received, %{text: "next"}),
               restored,
               spec
             )
  end

  test "rule checkpoint rejects invalid indices and malformed shapes" do
    spec = Spec.new(Rule, steps: ["one", "two"])

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%Rule{arguments: %{}, index: 3, results: []}, spec)

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%Rule{arguments: [], index: 1, results: []}, spec)
  end
end
