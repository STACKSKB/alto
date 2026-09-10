defmodule Alto.Tool do
  @moduledoc "Contract for model-facing tools. Tools do not share the provider contract."

  alias Alto.Tool.Context

  @type execution_mode :: :parallel | :exclusive
  @type approval_requirement :: :never | :required
  @type approval_details :: map()
  @type spec :: module() | {module(), keyword()}
  @type result :: {:ok, term()} | {:error, term()} | {:unknown, term()}

  @callback name() :: atom()
  @callback name(keyword()) :: atom()
  @callback schema() :: map()
  @callback schema(keyword()) :: map()
  @callback execution_mode() :: execution_mode()
  @callback execution_mode(keyword()) :: execution_mode()

  @doc """
  Declare how this tool is treated by the approval boundary.

  `:required` (the default for tools that omit this callback) routes every
  invocation through the configured approval policy. `:never` is an absolute
  opt-out: no approval policy is consulted and none can claw back a specific
  invocation once the tool has declared itself exempt. The tool's author is
  therefore the trust boundary for any `:never` tool, so reserve `:never` for
  tools that are genuinely side-effect-free.
  """
  @callback approval() :: approval_requirement()
  @callback approval(keyword()) :: approval_requirement()

  @doc """
  Validate and resolve an invocation before approval without performing it.

  A prepared tool returns an opaque value for `run_prepared` plus a map safe to
  show to the approval policy. Preparation may inspect local state to
  resolve names and policy, but must not produce the external effect being
  authorized. Implement `prepare` and `run_prepared` as a matching arity pair.
  """
  @callback prepare(arguments :: map(), Context.t()) ::
              {:ok, prepared :: term(), approval_details()} | {:error, term()}

  @callback prepare(arguments :: map(), Context.t(), keyword()) ::
              {:ok, prepared :: term(), approval_details()} | {:error, term()}

  @doc "Execute exactly the opaque value returned by the matching `prepare` callback."
  @callback run_prepared(prepared :: term(), Context.t()) ::
              result()

  @callback run_prepared(prepared :: term(), Context.t(), keyword()) ::
              result()

  @doc "Return `{:unknown, reason}` when dispatch occurred but commit cannot be established. Transport loss and timeouts are not participant declarations of non-commit."
  @callback run(arguments :: map(), Context.t()) :: result()
  @callback run(arguments :: map(), Context.t(), keyword()) :: result()

  @optional_callbacks name: 0,
                      name: 1,
                      schema: 0,
                      schema: 1,
                      execution_mode: 0,
                      execution_mode: 1,
                      approval: 0,
                      approval: 1,
                      prepare: 2,
                      prepare: 3,
                      run_prepared: 2,
                      run_prepared: 3,
                      run: 2,
                      run: 3
  def callback(module, callback, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, callback, 1) -> apply(module, callback, [opts])
      function_exported?(module, callback, 0) -> apply(module, callback, [])
      true -> raise ArgumentError, "#{inspect(module)} does not implement #{callback}/0 or /1"
    end
  end

  def requirement(module, opts) do
    cond do
      function_exported?(module, :approval, 1) -> module.approval(opts)
      function_exported?(module, :approval, 0) -> module.approval()
      true -> :required
    end
  end
end
