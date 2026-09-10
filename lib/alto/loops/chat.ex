defmodule Alto.Loops.Chat do
  @moduledoc "A minimal one-request conversational loop with no tool execution."

  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Transition

  defstruct [:task, :phase, :context]

  @type t :: %__MODULE__{task: term(), phase: :awaiting_model | :complete, context: term()}

  @impl true
  def init(task, %Spec{} = spec) do
    state = %__MODULE__{task: task, phase: :awaiting_model, context: spec.context}
    Transition.continue(state, [Effect.request_model(%{task: task, context: spec.context})])
  end

  @impl true
  def handle_event(
        %Event{type: :model_completed, data: data},
        %__MODULE__{phase: :awaiting_model} = state,
        _spec
      ) do
    case Map.get(data, :tool_calls, []) do
      [] ->
        output = Map.get(data, :message, Map.get(data, :output))
        Transition.stop(%{state | phase: :complete}, output)

      calls when is_list(calls) ->
        Transition.error(state, {:tools_not_supported, Enum.map(calls, &Map.get(&1, :id))})
    end
  end

  def handle_event(%Event{} = event, %__MODULE__{} = state, _spec) do
    Transition.error(state, {:unexpected_event, event.type, state.phase})
  end
end
