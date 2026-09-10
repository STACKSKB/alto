defmodule Alto.Loops.Default do
  @moduledoc """
  The shipped lean model/tool loop.

  It deliberately contains no Git policy, verification policy, compaction
  implementation, or provider behavior. Those are composed around it or replace
  it through the `Alto.Loop` contract.
  """

  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Transition

  defstruct [:task, :phase, :context, :subagents, step: 1, observations: []]

  @type continuation :: :request_model | {:stop, term()}
  @type phase ::
          :awaiting_model
          | {:awaiting_tools, %{required(term()) => pos_integer()}}
          | {:settling, continuation()}
  @type t :: %__MODULE__{
          task: term(),
          phase: phase(),
          context: term(),
          subagents: term(),
          step: pos_integer(),
          observations: [Event.t()]
        }

  @impl true
  def init(task, %Spec{} = spec) do
    state = %__MODULE__{
      task: task,
      phase: :awaiting_model,
      context: spec.context,
      subagents: spec.subagents
    }

    Transition.continue(state, [model_request(state)])
  end

  @impl true
  def handle_event(
        %Event{type: :model_completed, data: data},
        %__MODULE__{phase: :awaiting_model} = state,
        _spec
      ) do
    output = Map.get(data, :message, Map.get(data, :output))

    case Map.get(data, :tool_calls, []) do
      [] ->
        settle(state, {:stop, output}, :completed)

      tool_calls when is_list(tool_calls) ->
        # A provider may repeat a call id; every emitted invocation must
        # report before the step can settle.
        pending = Enum.frequencies_by(tool_calls, &Map.fetch!(&1, :id))
        effects = Enum.map(tool_calls, &Effect.run_tool/1)
        Transition.continue(%{state | phase: {:awaiting_tools, pending}}, effects)
    end
  end

  def handle_event(
        %Event{type: type} = event,
        %__MODULE__{phase: {:awaiting_tools, pending}} = state,
        _spec
      )
      when type in [:tool_completed, :tool_failed] do
    call_id = Map.fetch!(event.data, :call_id)
    next_state = %{state | observations: [event | state.observations]}

    case pending do
      %{^call_id => 1} ->
        if map_size(pending) == 1 do
          settle(next_state, :request_model, :tools_completed)
        else
          Transition.continue(%{
            next_state
            | phase: {:awaiting_tools, Map.delete(pending, call_id)}
          })
        end

      %{^call_id => count} when is_integer(count) and count > 1 ->
        Transition.continue(%{
          next_state
          | phase: {:awaiting_tools, Map.put(pending, call_id, count - 1)}
        })

      _other ->
        Transition.error(state, {:unknown_tool_call, call_id})
    end
  end

  def handle_event(
        %Event{type: :step_settled},
        %__MODULE__{phase: {:settling, :request_model}} = state,
        _spec
      ) do
    next_state = %{state | phase: :awaiting_model, step: state.step + 1, observations: []}
    Transition.continue(next_state, [model_request(next_state, Enum.reverse(state.observations))])
  end

  def handle_event(
        %Event{type: :step_settled},
        %__MODULE__{phase: {:settling, {:stop, result}}} = state,
        _spec
      ) do
    Transition.stop(state, result)
  end

  # step_settled hooks may emit run_tool effects, so their tool results can
  # arrive after the loop has left :awaiting_tools. They are observations,
  # not model tool calls, and must not change the pending continuation.
  def handle_event(
        %Event{type: type} = event,
        %__MODULE__{phase: {:settling, {:stop, result}}} = state,
        _spec
      )
      when type in [:tool_completed, :tool_failed] do
    Transition.stop(%{state | observations: [event | state.observations]}, result)
  end

  def handle_event(
        %Event{type: type} = event,
        %__MODULE__{phase: :awaiting_model} = state,
        _spec
      )
      when type in [:tool_completed, :tool_failed] do
    Transition.continue(%{state | observations: [event | state.observations]})
  end

  def handle_event(%Event{} = event, %__MODULE__{} = state, _spec) do
    Transition.error(state, {:unexpected_event, event.type, state.phase})
  end

  @impl true
  def dump_checkpoint(%__MODULE__{} = state, %Spec{}) do
    with :ok <- validate_checkpoint_state(state) do
      {:ok,
       %{
         task: state.task,
         phase: state.phase,
         step: state.step,
         observations: state.observations
       }}
    end
  end

  @impl true
  def load_checkpoint(checkpoint, %Spec{} = spec) do
    with true <- checkpoint_keys?(checkpoint),
         task <- Map.fetch!(checkpoint, :task),
         phase <- Map.fetch!(checkpoint, :phase),
         step <- Map.fetch!(checkpoint, :step),
         observations <- Map.fetch!(checkpoint, :observations),
         :ok <- validate_phase(phase),
         :ok <- validate_step(step),
         true <- is_list(observations) do
      {:ok,
       %__MODULE__{
         task: task,
         phase: phase,
         step: step,
         observations: observations,
         context: spec.context,
         subagents: spec.subagents
       }}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def load_checkpoint(_checkpoint, _spec), do: {:error, :invalid_checkpoint}

  defp checkpoint_keys?(checkpoint) when is_map(checkpoint) do
    Map.keys(checkpoint) |> Enum.sort() == [:observations, :phase, :step, :task]
  end

  defp checkpoint_keys?(_checkpoint), do: false

  defp validate_checkpoint_state(state) do
    with :ok <- validate_phase(state.phase),
         :ok <- validate_step(state.step),
         true <- is_list(state.observations) do
      :ok
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp validate_step(step) when is_integer(step) and step >= 1, do: :ok
  defp validate_step(_step), do: {:error, :invalid_checkpoint}

  defp validate_phase(:awaiting_model), do: :ok

  defp validate_phase({:awaiting_tools, pending}) when is_map(pending) do
    if Enum.all?(pending, fn {_id, count} -> is_integer(count) and count >= 1 end),
      do: :ok,
      else: {:error, :invalid_checkpoint}
  end

  defp validate_phase({:settling, :request_model}), do: :ok
  defp validate_phase({:settling, {:stop, _result}}), do: :ok
  defp validate_phase(_phase), do: {:error, :invalid_checkpoint}

  defp settle(state, continuation, outcome) do
    event =
      Event.durable(:step_settled, %{
        step: state.step,
        outcome: outcome
      })

    Transition.continue(%{state | phase: {:settling, continuation}}, [Effect.emit(event)])
  end

  defp model_request(state, observations \\ []) do
    Effect.request_model(%{
      task: state.task,
      step: state.step,
      context: state.context,
      observations: observations
    })
  end
end
