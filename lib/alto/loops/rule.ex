defmodule Alto.Loops.Rule do
  @moduledoc """
  The shipped provider-less rule loop: a finite script of tool invocations.

  The task carries the run's payload — typically a webhook body, a JSON
  object — while the steps are compiled configuration, selected through
  `Alto.rule_loop(steps: [...])`. A step is a tool name (arguments default
  to the decoded task) or `%{tool: name, arguments: map() | :task}`, where
  `:task` means the decoded task object. An argument function of arity two receives
  the original task and prior native results in step order. The result is a list
  of native tool values; provider serialization is not part of this interface. The loop emits `Effect.invoke_tool/1`
  effects — native argument maps, no JSON round-trip — so every invocation
  crosses the same prepare, approval, bounds, and supervision boundaries as a
  model-driven call. The run stops when the last tool completes and fails
  fast on the first tool failure; no model effect is ever requested, so no
  provider is needed.

  Correlation uses the deterministic step id (`"rule-<index>"`) as `call_id`.
  Approval handles are the host's globally unique operations
  (`"<run_id>:op-<seq>"`), so concurrent runs with identical step numbers
  approve independently.
  """

  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Transition

  defstruct [:arguments, steps: [], index: 1, results: []]

  @type step :: binary() | %{optional(:tool) => binary(), optional(:arguments) => term()}
  @type t :: %__MODULE__{
          arguments: map(),
          steps: [step()],
          index: pos_integer(),
          results: [term()]
        }

  @impl true
  def init(task, %Spec{} = spec) do
    with {:ok, steps} <- steps(spec),
         {:ok, arguments} <- decode_task(task) do
      state = %__MODULE__{steps: steps, arguments: arguments}
      Transition.continue(state, [invoke(state)])
    else
      {:error, reason} -> Transition.error(%__MODULE__{}, reason)
    end
  end

  @impl true
  def handle_event(
        %Event{type: :tool_completed, data: %{call_id: call_id} = data},
        %__MODULE__{} = state,
        _spec
      ) do
    if call_id == call_id(state) do
      state = %{state | results: [Map.get(data, :value, Map.get(data, :output)) | state.results]}

      case next_step(state) do
        {:ok, state} -> Transition.continue(state, [invoke(state)])
        :done -> Transition.stop(state, Enum.reverse(state.results))
      end
    else
      Transition.continue(state)
    end
  end

  def handle_event(
        %Event{type: :tool_failed, data: %{call_id: call_id, error: error}},
        %__MODULE__{} = state,
        _spec
      ) do
    if call_id == call_id(state) do
      Transition.error(state, {:rule_step_failed, state.index, current_tool(state), error})
    else
      Transition.continue(state)
    end
  end

  def handle_event(%Event{}, %__MODULE__{} = state, _spec), do: Transition.continue(state)

  ## Internals

  defp steps(%Spec{} = spec) do
    case Keyword.get(spec.driver_options, :steps) do
      steps when is_list(steps) and steps != [] ->
        if Enum.all?(steps, &valid_step?/1), do: {:ok, steps}, else: {:error, :invalid_steps}

      _other ->
        {:error, :invalid_steps}
    end
  end

  defp valid_step?(name) when is_binary(name) and name != "", do: true

  # A map step may carry `:arguments` as a map, the `:task` marker, or
  # nothing at all (the two-key clause must precede the one-key clause:
  # every map pattern also matches maps with extra keys).
  defp valid_step?(%{tool: tool, arguments: arguments}) when is_binary(tool) and tool != "",
    do: step_arguments_valid?(arguments)

  defp valid_step?(%{tool: tool}) when is_binary(tool) and tool != "", do: true

  defp valid_step?(_other), do: false

  defp step_arguments_valid?(arguments) when is_map(arguments), do: true
  defp step_arguments_valid?(arguments) when is_function(arguments, 2), do: true
  defp step_arguments_valid?(:task), do: true
  defp step_arguments_valid?(nil), do: true
  defp step_arguments_valid?(_other), do: false

  # The task is the run's payload: a JSON object string (a webhook body) or
  # an already-decoded map. Anything else fails closed — a rule run without
  # a structured payload has nothing to act on.
  defp decode_task(task) when is_binary(task) do
    case JSON.decode(task) do
      {:ok, %{} = arguments} -> {:ok, arguments}
      _other -> {:error, :invalid_task}
    end
  end

  defp decode_task(task) when is_map(task), do: {:ok, task}
  defp decode_task(_task), do: {:error, :invalid_task}

  defp invoke(%__MODULE__{} = state) do
    Effect.invoke_tool(%{
      id: call_id(state),
      name: current_tool(state),
      arguments: current_arguments(state)
    })
  end

  defp call_id(%__MODULE__{index: index}), do: "rule-" <> Integer.to_string(index)

  defp current_tool(%__MODULE__{steps: [step | _rest]}) when is_binary(step), do: step
  defp current_tool(%__MODULE__{steps: [%{tool: tool} | _rest]}), do: tool

  defp current_arguments(%__MODULE__{steps: [step | _rest], arguments: task_arguments} = state) do
    case step do
      %{arguments: :task} ->
        task_arguments

      %{arguments: arguments} when is_map(arguments) ->
        arguments

      %{arguments: arguments} when is_function(arguments, 2) ->
        arguments.(task_arguments, Enum.reverse(state.results))

      _other ->
        task_arguments
    end
  end

  defp next_step(%__MODULE__{steps: [_current | rest]} = state) when rest != [],
    do: {:ok, %{state | steps: rest, index: state.index + 1}}

  defp next_step(%__MODULE__{steps: [_current | _rest]}), do: :done
end
