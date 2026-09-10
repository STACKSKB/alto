defmodule Alto.Runner.Execution.Tool do
  @moduledoc "The bounded preparation, approval, and invocation boundary for tools."

  alias Alto.Approval.Request
  alias Alto.Event
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call

  defmodule Capabilities do
    @moduledoc "Tool authority and bounds needed by the execution boundary."
    @enforce_keys [:tools, :approval, :context, :budget]
    defstruct tools: %{},
              approval: {Alto.Approvals.DenyAll, []},
              context: nil,
              budget: nil,
              cancel_ref: nil,
              tool_timeout: 125_000,
              approval_timeout: 300_000,
              max_approval_details_bytes: 64_000,
              max_tool_result_bytes: 64_000,
              event_sink: nil

    @type t :: %__MODULE__{
            tools: %{optional(binary()) => map()},
            approval: {module(), keyword()},
            context: Alto.Tool.Context.t(),
            budget: Budget.t(),
            cancel_ref: reference() | nil,
            tool_timeout: pos_integer(),
            approval_timeout: pos_integer(),
            max_approval_details_bytes: pos_integer(),
            max_tool_result_bytes: pos_integer(),
            event_sink: (Event.t() -> term()) | nil
          }
  end

  @doc "Prepare one invocation and return the opaque value and display-safe details."
  def prepare(%{preparation: :none}, arguments, _caps), do: {:ok, arguments, %{}}

  def prepare(tool, arguments, %Capabilities{} = caps) do
    outcome =
      Call.run(
        fn -> invoke_prepare(tool, arguments, caps.context) end,
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
  def authorize(_call_id, _name, _arguments, _details, %{approval: :never}, _caps, _operation_id),
    do: :ok

  def authorize(call_id, name, arguments, details, tool, %Capabilities{} = caps, operation_id) do
    {policy, policy_opts} = caps.approval

    request = %Request{
      id: operation_id,
      run_id: caps.context.session_id,
      call_id: call_id,
      operation_id: operation_id,
      tool: name,
      arguments: arguments,
      execution_mode: tool.execution_mode,
      details: details
    }

    notify(caps.event_sink, Event.live(:approval_requested, %{request: request}))

    outcome =
      Call.run(
        fn -> policy.decide(request, caps.context, policy_opts) end,
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

    notify(
      caps.event_sink,
      Event.live(:approval_resolved, %{request: request, decision: decision_name(decision)})
    )

    decision
  end

  @doc "Invoke a prepared value exactly once under the tool bound.

  The supervision envelope is retained so hosts can distinguish a
  participant-reported failure from a crashed or timed out participant.
  "
  def invoke(tool, prepared, %Capabilities{} = caps) do
    case Call.cancellation(caps.cancel_ref) do
      {:cancelled, reason} ->
        {:cancelled, reason}

      :continue ->
        outcome =
          Call.run(
            fn -> invoke_tool(tool, prepared, caps.context) end,
            Budget.timeout(caps.budget, caps.tool_timeout),
            caps.cancel_ref
          )

        case outcome do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, reason}
          {:cancelled, reason} -> {:cancelled, reason}
        end
    end
  end

  @doc "Compose prepare, approval and invocation for hosts that use one call."
  def execute(call_id, name, arguments, tool, %Capabilities{} = caps, operation_id) do
    case prepare(tool, arguments, caps) do
      {:ok, prepared, details} ->
        case authorize(call_id, name, arguments, details, tool, caps, operation_id) do
          :ok -> invoke(tool, prepared, caps)
          {:suspend, request} -> {:suspend, %{request: request, prepared: prepared}}
          {:deny, reason} -> {:error, {:approval_denied, reason}}
          {:error, reason} -> {:error, {:approval_failed, reason}}
          {:cancelled, reason} -> {:cancelled, reason}
        end

      {:error, reason} ->
        {:error, reason}

      {:cancelled, reason} ->
        {:cancelled, reason}
    end
  end

  @doc "Check native result size before event retention or persistence."
  def check_native_result(value, limit) when is_integer(limit) and limit > 0 do
    size = :erlang.external_size(value)

    if size <= limit,
      do: :ok,
      else: {:error, {:tool_result_too_large, %{limit: limit, size: size}}}
  end

  defp invoke_prepare(%{module: module, preparation: :arity2}, arguments, context),
    do: module.prepare(arguments, context)

  defp invoke_prepare(%{module: module, opts: opts, preparation: :arity3}, arguments, context),
    do: module.prepare(arguments, context, opts)

  defp invoke_tool(%{module: module, preparation: :arity2}, prepared, context),
    do: module.run_prepared(prepared, context)

  defp invoke_tool(%{module: module, opts: opts, preparation: :arity3}, prepared, context),
    do: module.run_prepared(prepared, context, opts)

  defp invoke_tool(%{module: module, opts: []}, arguments, context),
    do: module.run(arguments, context)

  defp invoke_tool(%{module: module, opts: opts}, arguments, context),
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
  defp notify(nil, _), do: :ok

  defp notify(sink, event) do
    sink.(event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
