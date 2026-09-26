defmodule Alto.Command do
  @moduledoc "Compose command validation policy separately from its execution backend."

  alias Alto.Command.Executors.Unsandboxed
  alias Alto.Command.Invocation
  alias Alto.Command.Prepared
  alias Alto.Command.Policies.Unrestricted
  alias Alto.Tool.Context

  @type component :: {module(), keyword()}

  @spec prepare(map(), Context.t(), keyword()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(arguments, %Context{} = context, opts \\ []) do
    {policy, policy_opts} = Keyword.get(opts, :policy, {Unrestricted, []})
    {executor, executor_opts} = Keyword.get(opts, :executor, {Unsandboxed, []})

    with {:ok, %Invocation{} = invocation} <- policy.prepare(arguments, context, policy_opts),
         {:ok, execution, executor_details} when is_map(executor_details) <-
           executor.prepare(invocation, executor_opts) do
      {:ok,
       %Prepared{
         executor: executor,
         execution: execution,
         approval_details: %{command: Map.from_struct(invocation), execution: executor_details}
       }}
    else
      {:error, _} = error -> error
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
end
