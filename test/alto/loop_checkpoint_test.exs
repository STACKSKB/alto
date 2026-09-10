defmodule Alto.LoopCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.Loop.Spec
  alias Alto.Loops.{Chat, Default, Rule}
  alias Alto.Runtime

  test "default and chat checkpoints restore trusted spec state" do
    spec = Spec.new(Default, context: %{window: 1}, subagents: %{depth: 2})

    state = %Default{
      task: "task",
      phase: {:awaiting_tools, %{"call" => 2}},
      context: :runtime_context,
      subagents: :runtime_subagents,
      step: 4,
      observations: [Alto.Event.durable(:tool_completed, %{})]
    }

    assert {:ok, checkpoint} = Default.dump_checkpoint(state, spec)
    refute Map.has_key?(checkpoint, :context)
    refute Map.has_key?(checkpoint, :subagents)
    assert {:ok, restored} = Default.load_checkpoint(checkpoint, spec)
    assert restored.task == state.task
    assert restored.phase == state.phase
    assert restored.step == state.step
    assert restored.observations == state.observations
    assert restored.context == spec.context
    assert restored.subagents == spec.subagents

    chat_spec = Spec.new(Chat, context: %{window: 3})

    assert {:ok, chat_checkpoint} =
             Chat.dump_checkpoint(%Chat{task: "hi", phase: :complete, context: :old}, chat_spec)

    assert {:ok, %Chat{task: "hi", phase: :complete, context: %{window: 3}}} =
             Chat.load_checkpoint(chat_checkpoint, chat_spec)
  end

  test "rule checkpoint rehydrates trusted function steps" do
    function = fn task, results -> %{"task" => task["id"], "prior" => results} end
    spec = Spec.new(Rule, steps: [%{tool: "first", arguments: function}, "second"])

    state = %Rule{
      steps: [%{tool: "first", arguments: function}, "second"],
      index: 1,
      arguments: %{"id" => "job"},
      results: []
    }

    assert {:ok, checkpoint} = Rule.dump_checkpoint(state, spec)
    refute Map.has_key?(checkpoint, :steps)
    assert {:ok, restored} = Rule.load_checkpoint(checkpoint, spec)
    assert restored.steps == spec.driver_options[:steps]

    assert [%{data: %{arguments: %{"task" => "job", "prior" => []}}}] =
             Runtime.init(spec, restored.arguments).effects
  end

  test "rule checkpoint rejects invalid indices and malformed shapes" do
    spec = Spec.new(Rule, steps: ["one", "two"])

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%{arguments: %{}, index: 3, results: []}, spec)

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%{arguments: [], index: 1, results: []}, spec)
  end
end
