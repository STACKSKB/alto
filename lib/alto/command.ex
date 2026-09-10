defmodule Alto.Command do
  @moduledoc "Compose command validation policy separately from its execution backend."

  alias Alto.Command.Executors.Unsandboxed
  alias Alto.Command.Invocation
  alias Alto.Command.Prepared
  alias Alto.Command.Policies.Unrestricted
  alias Alto.Tool.Context

  @type component :: module() | {module(), keyword()}

  @spec prepare(map(), Context.t(), keyword()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(arguments, %Context{} = context, opts \\ []) do
    with {:ok, {policy, policy_opts}} <-
           opts |> Keyword.get(:policy, Unrestricted) |> normalize(:policy),
         {:ok, {executor, executor_opts}} <-
           opts |> Keyword.get(:executor, Unsandboxed) |> normalize(:executor),
         {:ok, invocation} <- prepare_invocation(policy, arguments, context, policy_opts),
         {:ok, execution, executor_details} <-
           prepare_execution(executor, invocation, executor_opts) do
      {:ok,
       %Prepared{
         invocation: invocation,
         executor: executor,
         execution: execution,
         approval_details: approval_details(invocation, executor_details)
       }}
    end
  end

  @spec execute(Prepared.t()) :: {:ok, map()} | {:error, term()}
  def execute(%Prepared{executor: executor, execution: execution}) do
    executor.execute(execution)
  end

  @spec run(map(), Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(arguments, %Context{} = context, opts \\ []) do
    with {:ok, prepared} <- prepare(arguments, context, opts) do
      execute(prepared)
    end
  end

  defp approval_details(invocation, executor_details) do
    %{
      command: %{
        requested_program: invocation.requested_program,
        executable: invocation.executable,
        args: invocation.args,
        cwd: invocation.cwd,
        timeout_ms: invocation.timeout_ms,
        max_output_bytes: invocation.max_output_bytes
      },
      execution: executor_details
    }
  end

  defp prepare_invocation(policy, arguments, context, opts) do
    case policy.prepare(arguments, context, opts) do
      {:ok, %Invocation{} = invocation} -> {:ok, invocation}
      {:ok, other} -> {:error, {:invalid_command_invocation, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_command_policy_return, other}}
    end
  end

  defp prepare_execution(executor, invocation, opts) do
    case executor.prepare(invocation, opts) do
      {:ok, execution, details} when is_map(details) -> {:ok, execution, details}
      {:ok, _execution, details} -> {:error, {:invalid_executor_approval_details, details}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_command_executor_return, other}}
    end
  end

  defp normalize({module, opts}, kind) when is_atom(module) and is_list(opts),
    do: validate_component(module, opts, kind)

  defp normalize(module, kind) when is_atom(module), do: validate_component(module, [], kind)
  defp normalize(other, _kind), do: {:error, {:invalid_command_component, other}}

  defp validate_component(module, opts, :policy) do
    validate_callback(module, opts, :prepare, 3, :policy)
  end

  defp validate_component(module, opts, :executor) do
    with {:ok, component} <- validate_callback(module, opts, :prepare, 2, :executor),
         true <- function_exported?(module, :execute, 1) do
      {:ok, component}
    else
      false -> {:error, {:invalid_command_component, :executor, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_callback(module, opts, function, arity, kind) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      {:ok, {module, opts}}
    else
      {:error, {:invalid_command_component, kind, module}}
    end
  end
end
