defmodule Alto.Loops.Chat do
  @moduledoc "A tool-free conversational policy over the default model loop."

  @behaviour Alto.Loop

  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Loops.Default
  alias Alto.Transition

  @impl true
  def init(task, spec), do: Default.init(task, tool_free(spec))

  @impl true
  def handle_event(%Event{type: type} = event, state, spec)
      when type in [:input_received, :model_completed],
      do: Default.handle_event(event, state, tool_free(spec))

  def handle_event(%Event{} = event, state, _spec),
    do: Transition.error(state, {:unexpected_event, event.type, state.phase})

  @impl true
  def dump_checkpoint(%Default{phase: :awaiting_model} = state, spec),
    do: Default.dump_checkpoint(state, tool_free(spec))

  def dump_checkpoint(_, _), do: {:error, :invalid_checkpoint}

  @impl true
  def load_checkpoint(state, spec), do: dump_checkpoint(state, spec)

  defp tool_free(%Spec{} = spec),
    do: %{spec | driver_options: Keyword.put(spec.driver_options, :tool_execution, :disabled)}
end
