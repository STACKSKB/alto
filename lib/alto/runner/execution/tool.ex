defmodule Alto.Runner.Execution.Tool do
  @moduledoc """
  Bounded tool preparation, approval, and invocation over a capability map.

  Operations consume `tool_context`, `budget`, cancellation, timeout, approval,
  and event-sink fields using the same names as the execution run. Tool and
  policy callbacks receive only their explicit context and arguments.
  """

  alias Alto.Approval.Request
  alias Alto.Event
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call

  @doc "Prepare one invocation and return the opaque value and display-safe details."
  def prepare(%{preparation: :none}, arguments, _caps), do: {:ok, arguments, %{}}

  def prepare(tool, arguments, caps) do
    context = caps.tool_context

    outcome =
      Call.run(
        fn -> invoke_prepare(tool, arguments, context) end,
        Budget.timeout(caps.budget, caps.tool_timeout),
        caps.cancel_ref
      )

    case outcome do
      {:ok, {:ok, prepared, details}} when is_map(details) ->
        bound_details(prepared, details, caps.max_approval_details_bytes)

      {:ok, {:ok, _prepared, details}} ->
        {:error, {:invalid_approval_details, details}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_tool_prepare_return, other}}

      {:error, reason} ->
        {:error, {:tool_prepare_process_failed, reason}}

      {:cancelled, reason} ->
        {:cancelled, reason}
    end
  end

  @doc "Authorize the exact prepared value's operation."
  def authorize(%{tool: %{approval: :never}}, _details, _caps),
    do: :ok

  def authorize(job, details, caps) do
    {policy, policy_opts} = caps.approval
    context = caps.tool_context

    request = %Request{
      id: job.op_id,
      run_id: context.session_id,
      call_id: job.id,
      operation_id: job.op_id,
      tool: job.name,
      arguments: job.arguments,
      execution_mode: job.tool.execution_mode,
      details: details
    }

    Alto.Events.notify(caps.event_sink, Event.live(:approval_requested, %{request: request}))

    outcome =
      Call.run(
        fn -> policy.decide(request, context, policy_opts) end,
        Budget.timeout(caps.budget, caps.approval_timeout),
        caps.cancel_ref
      )

    decision =
      case outcome do
        {:ok, :approve} -> :ok
        {:ok, :suspend} -> {:suspend, request}
        {:ok, {:deny, reason}} -> {:deny, reason}
        {:ok, other} -> {:error, {:invalid_decision, other}}
        {:error, reason} -> {:error, {:policy_process_failed, reason}}
        {:cancelled, reason} -> {:cancelled, reason}
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

  defp invoke_prepare(%{module: module, opts: opts}, arguments, context),
    do: module.prepare(arguments, context, opts)

  @doc "Invoke directly inside an already supervised, bounded worker."
  def invoke_tool(%{module: module, opts: opts, preparation: :prepared}, prepared, context),
    do: module.run_prepared(prepared, context, opts)

  def invoke_tool(%{module: module, opts: opts}, arguments, context),
    do: module.run(arguments, context, opts)

  defp bound_details(prepared, details, limit) do
    if :erlang.external_size(details) <= limit,
      do: {:ok, prepared, details},
      else: {:error, {:approval_details_limit, limit}}
  end

  defp decision_name({:suspend, _}), do: :suspended
  defp decision_name(:ok), do: :approved
  defp decision_name({:deny, reason}), do: {:denied, reason}
  defp decision_name({:error, reason}), do: {:error, reason}
  defp decision_name({:cancelled, reason}), do: {:cancelled, reason}
end
