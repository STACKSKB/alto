defmodule Alto.Loops.Rule do
  @moduledoc """
  The shipped provider-less rule loop: a finite script of tool invocations.

  The task carries the run's payload — typically a webhook body, a JSON
  object — while the steps are compiled configuration, selected through
  `Alto.rule_loop(steps: [...])`. A step is a tool name (arguments default
  to the decoded task) or `%{tool: name, arguments: map() | :task}`, where
  `:task` means the decoded task object. An argument function of arity two receives
  the original task and prior native results in step order. The result is a list
  of native tool values; provider serialization is not part of this interface. The loop emits `{:invoke_tool, call}`
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
  alias Alto.Event

  @type t :: {pos_integer(), map(), [term()]}

  @doc false
  def compile_steps([_ | _] = steps), do: steps |> Enum.map(&compile_step/1) |> List.to_tuple()
  def compile_steps(_), do: raise(ArgumentError, "rule steps must be a nonempty list")

  defp compile_step(tool) when is_binary(tool) and tool != "", do: {tool, :task}

  defp compile_step(%{tool: tool} = step) when is_binary(tool) and tool != "" do
    case Map.get(step, :arguments, :task) do
      nil ->
        {tool, :task}

      arguments when is_map(arguments) or is_function(arguments, 2) or arguments == :task ->
        {tool, arguments}

      _ ->
        raise ArgumentError, "invalid rule step arguments"
    end
  end

  defp compile_step(_), do: raise(ArgumentError, "invalid rule step")

  @impl true
  def init(task, spec) do
    case decode_task(task) do
      {:ok, arguments} ->
        state = {1, arguments, []}
        {:continue, state, [invoke(state, spec.driver_options[:steps])]}

      {:error, reason} ->
        {{:error, reason}, nil, []}
    end
  end

  @impl true
  def handle_event(
        %Event{type: type, data: %{call_id: id} = data},
        {index, arguments, results} = state,
        spec
      )
      when type in [:tool_completed, :tool_failed] do
    steps = spec.driver_options[:steps]

    cond do
      id != call_id(index) ->
        {:continue, state, []}

      type == :tool_failed ->
        {tool, _} = elem(steps, index - 1)
        {{:error, {:rule_step_failed, index, tool, data.error}}, state, []}

      true ->
        results = [data.value | results]
        state = {index, arguments, results}

        if index == tuple_size(steps) do
          {{:stop, Enum.reverse(results)}, state, []}
        else
          next = {index + 1, arguments, results}
          {:continue, next, [invoke(next, steps)]}
        end
    end
  end

  def handle_event(%Event{}, state, _spec), do: {:continue, state, []}

  @impl true
  def dump_checkpoint({index, arguments, results} = state, spec) do
    if is_integer(index) and index >= 1 and index <= tuple_size(spec.driver_options[:steps]) and
         is_map(arguments) and is_list(results),
       do: {:ok, state},
       else: {:error, :invalid_checkpoint}
  end

  def dump_checkpoint(_, _), do: {:error, :invalid_checkpoint}

  @impl true
  def load_checkpoint(state, spec), do: dump_checkpoint(state, spec)

  # The task is the structured run payload; argument functions see it and prior
  # native results in script order. Plain compiled steps remain portable data.
  defp decode_task(task) when is_binary(task) do
    case JSON.decode(task) do
      {:ok, %{} = arguments} -> {:ok, arguments}
      _ -> {:error, :invalid_task}
    end
  end

  defp decode_task(task) when is_map(task), do: {:ok, task}
  defp decode_task(_), do: {:error, :invalid_task}

  defp invoke({index, task, results}, steps) do
    {tool, arguments} = elem(steps, index - 1)

    arguments =
      case arguments do
        :task -> task
        resolve when is_function(resolve, 2) -> resolve.(task, Enum.reverse(results))
        arguments -> arguments
      end

    {:invoke_tool, %{id: call_id(index), name: tool, arguments: arguments}}
  end

  defp call_id(index), do: "rule-" <> Integer.to_string(index)
end
