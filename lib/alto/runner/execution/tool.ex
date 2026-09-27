defmodule Alto.Runner.Execution.Tool do
  @moduledoc """
  Bounded tool preparation, approval, and invocation over a capability map.

  Operations consume context fields, budget, cancellation, timeout, approval,
  and event-sink fields using the same names as the execution run. Tool and
  policy callbacks receive only their explicit context and arguments.
  """

  alias Alto.Event
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call

  @doc "Prepare one invocation and return the opaque value and display-safe details."
  def prepare(%{module: module, opts: opts}, arguments, caps) do
    if function_exported?(module, :prepare, 3) or function_exported?(module, :arguments, 1) do
      outcome =
        Call.run(
          fn -> Alto.Tool.prepare(module, arguments, Alto.Tool.context(caps), opts) end,
          Budget.timeout(caps.budget, caps.tool_timeout),
          caps.cancel_ref
        )

      case outcome do
        {:ok, prepared, details} ->
          bound_details(prepared, details, caps.max_approval_details_bytes)

        {:error, _} = error ->
          error
      end
    else
      {:ok, arguments, %{}}
    end
  end

  @doc "Authorize the exact prepared value's operation."
  def authorize(%{tool: %{approval: :never}}, _details, _caps),
    do: :ok

  def authorize(job, details, caps) do
    context = Alto.Tool.context(caps)

    request = %{
      id: job.op_id,
      run_id: context.session_id,
      call_id: job.id,
      tool: job.name,
      arguments: job.arguments,
      execution_mode: job.tool.execution_mode,
      details: details
    }

    Alto.Events.notify(caps.event_sink, Event.live(:approval_requested, %{request: request}))

    outcome =
      Call.run(
        fn ->
          case caps.approval do
            policy when is_function(policy, 2) -> policy.(request, context)
            decision -> decision
          end
        end,
        Budget.timeout(caps.budget, caps.approval_timeout),
        caps.cancel_ref
      )

    decision =
      case outcome do
        :approve -> :ok
        :suspend -> {:suspend, request}
        {:deny, reason} -> {:deny, reason}
        {:error, _} = error -> error
        other -> {:error, {:invalid_decision, other}}
      end

    Alto.Events.notify(
      caps.event_sink,
      Event.live(:approval_resolved, %{request: request, decision: decision_name(decision)})
    )

    decision
  end

  @doc "Check native result size before event retention or persistence."
  def check_native_result(value, limit) when is_integer(limit) and limit > 0 do
    size = :erlang.external_size(value)

    if size <= limit,
      do: :ok,
      else: {:error, {:tool_result_too_large, %{limit: limit, size: size}}}
  end

  # Match sequential execution: a successful participant value is the bounded
  # native result, rather than the surrounding outcome tuple.
  def bound_result(outcome, limit) do
    value =
      case outcome do
        {:ok, value} -> value
        other -> other
      end

    case {check_native_result(value, limit), outcome} do
      {:ok, {:ok, value}} -> {:completed, value}
      {:ok, {:error, reason}} -> {:failed_known, reason}
      {:ok, {:unknown, reason}} -> {:unknown, reason}
      {:ok, other} -> {:unknown, {:invalid_tool_return, other}}
      {{:error, reason}, _} -> {:unknown, reason}
    end
  end

  @doc "Invoke directly inside an already supervised, bounded worker."
  def invoke_tool(%{module: Alto.Tools.ListAgentModels, opts: opts}, prepared, caps),
    do: Alto.Subagents.Models.list(prepared, caps, opts)

  def invoke_tool(%{module: module, opts: opts}, arguments, caps),
    do: module.run(arguments, Alto.Tool.context(caps), opts)

  defp bound_details(prepared, details, limit) do
    if :erlang.external_size(details) <= limit,
      do: {:ok, prepared, details},
      else: {:error, {:approval_details_limit, limit}}
  end

  defp decision_name({:suspend, _}), do: :suspended
  defp decision_name(:ok), do: :approved
  defp decision_name({:deny, reason}), do: {:denied, reason}
  defp decision_name({:error, {:cancelled, reason}}), do: {:cancelled, reason}
  defp decision_name({:error, reason}), do: {:error, reason}
end
