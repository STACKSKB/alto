defmodule Alto.Loops.Chat do
  @moduledoc "A minimal one-request conversational loop with no tool execution."

  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Transition

  defstruct [:task, :phase]

  @type t :: %__MODULE__{task: term(), phase: :awaiting_model | :complete}

  @impl true
  def init(task, %Spec{} = spec) do
    state = %__MODULE__{task: task, phase: :awaiting_model}
    Transition.continue(state, [Effect.request_model(%{task: task, context: spec.context})])
  end

  @impl true
  def handle_event(%Event{type: :input_received, data: %{text: text}}, state, spec) do
    next = %{state | task: text, phase: :awaiting_model}
    Transition.continue(next, [Effect.request_model(%{task: text, context: spec.context})])
  end

  @impl true
  def handle_event(
        %Event{type: :model_completed, data: %{message: output} = data},
        %__MODULE__{phase: :awaiting_model} = state,
        _spec
      ) do
    case Map.get(data, :tool_calls, []) do
      [] ->
        Transition.stop(%{state | phase: :complete}, output)

      calls when is_list(calls) ->
        Transition.error(state, {:tools_not_supported, Enum.map(calls, &Map.get(&1, :id))})
    end
  end

  def handle_event(%Event{} = event, %__MODULE__{} = state, _spec) do
    Transition.error(state, {:unexpected_event, event.type, state.phase})
  end

  @impl true
  def dump_checkpoint(%__MODULE__{phase: phase} = state, %Spec{})
      when map_size(state) == 3 and phase in [:awaiting_model, :complete],
      do: {:ok, state}

  def dump_checkpoint(_state, _spec), do: {:error, :invalid_checkpoint}

  @impl true
  def load_checkpoint(state, spec), do: dump_checkpoint(state, spec)
end
