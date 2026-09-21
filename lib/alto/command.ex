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
           opts
           |> Keyword.get(:policy, Unrestricted)
           |> Alto.Capabilities.resolve(Alto.Command.Policy),
         {:ok, {executor, executor_opts}} <-
           opts
           |> Keyword.get(:executor, Unsandboxed)
           |> Alto.Capabilities.resolve(Alto.Command.Executor),
         {:ok, invocation} <- prepare_invocation(policy, arguments, context, policy_opts),
         {:ok, execution, executor_details} <-
           prepare_execution(executor, invocation, executor_opts) do
      {:ok,
       %Prepared{
         executor: executor,
         execution: execution,
         approval_details: %{command: Map.from_struct(invocation), execution: executor_details}
       }}
    end
  end

  @spec execute(Prepared.t()) :: {:ok, map()} | {:error, term()}
  def execute(%Prepared{executor: executor, execution: execution}) do
    executor.execute(execution)
  end

  @doc "Open an already prepared execution for a bounded, retained stdio client."
  def open(%Prepared{executor: executor, execution: execution}, opts \\ []) do
    if function_exported?(executor, :open, 2),
      do: executor.open(execution, opts),
      else: {:error, {:executor_stdio_unsupported, executor}}
  end

  @spec run(map(), Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(arguments, %Context{} = context, opts \\ []) do
    with {:ok, prepared} <- prepare(arguments, context, opts) do
      execute(prepared)
    end
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
end
