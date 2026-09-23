defmodule Alto.LoopCheckpointTest do
  use ExUnit.Case, async: true

  alias Alto.Loop.Spec
  alias Alto.Loops.{Chat, Default, Rule}
  alias Alto.Runtime

  test "default and chat checkpoints restore runtime state and use the current spec" do
    spec = Spec.new(Default, context: %{window: 1}, subagents: %{depth: 2})

    state = %Default{
      task: "task",
      phase: {:awaiting_tools, %{"call" => 2}},
      step: 4,
      observations: [Alto.Event.durable(:tool_completed, %{})]
    }

    assert {:ok, checkpoint} = Default.dump_checkpoint(state, spec)
    refute Map.has_key?(checkpoint, :context)
    refute Map.has_key?(checkpoint, :subagents)
    assert {:ok, restored} = Default.load_checkpoint(checkpoint, spec)
    assert restored == state
    next = Default.handle_event(Alto.Event.live(:input_received, %{text: "next"}), restored, spec)
    assert [%{data: %{context: %{window: 1}}}] = next.effects

    chat_spec = Spec.new(Chat, context: %{window: 3})
    chat_state = Runtime.init(chat_spec, "hi").state

    assert {:ok, ^chat_state} = Chat.dump_checkpoint(chat_state, chat_spec)
    assert {:ok, ^chat_state} = Chat.load_checkpoint(chat_state, chat_spec)

    assert {:error, :invalid_checkpoint} =
             Chat.load_checkpoint(%{chat_state | phase: {:awaiting_tools, %{}}}, chat_spec)

    next =
      Chat.handle_event(Alto.Event.live(:input_received, %{text: "next"}), chat_state, chat_spec)

    assert [%{data: %{context: %{window: 3}}}] = next.effects
  end

  test "rule checkpoint excludes configured function steps" do
    function = fn task, results -> %{"task" => task["id"], "prior" => results} end
    spec = Spec.new(Rule, steps: [%{tool: "first", arguments: function}, "second"])

    state = %Rule{
      index: 1,
      arguments: %{"id" => "job"},
      results: []
    }

    assert {:ok, dumped} = Rule.dump_checkpoint(state, spec)
    assert {:ok, encoded} = Alto.Persistence.Codec.encode(dumped)
    assert {:ok, checkpoint} = Alto.Persistence.Codec.decode(encoded)
    refute Map.has_key?(checkpoint, :steps)
    assert {:ok, restored} = Rule.load_checkpoint(checkpoint, spec)
    assert restored == state

    assert [%{data: %{arguments: %{"task" => "job", "prior" => []}}}] =
             Runtime.init(spec, restored.arguments).effects
  end

  test "rule checkpoint rejects invalid indices and malformed shapes" do
    spec = Spec.new(Rule, steps: ["one", "two"])

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%Rule{arguments: %{}, index: 3, results: []}, spec)

    assert {:error, :invalid_checkpoint} =
             Rule.load_checkpoint(%Rule{arguments: [], index: 1, results: []}, spec)
  end
end
