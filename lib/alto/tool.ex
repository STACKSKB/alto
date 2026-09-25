defmodule Alto.Tool do
  @moduledoc "Contract for model-facing tools. Tools do not share the provider contract."

  alias Alto.Tool.Context

  @type execution_mode :: :parallel | :exclusive
  @type approval_requirement :: :never | :required
  @type approval_details :: map()
  @type spec :: module() | {module(), keyword()}
  @type result :: {:ok, term()} | {:error, term()} | {:unknown, term()}

  @callback name(keyword()) :: atom()
  @callback schema(keyword()) :: map()
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
  @callback approval(keyword()) :: approval_requirement()

  @doc """
  Validate and resolve an invocation before approval without performing it.

  A prepared tool returns an opaque value for `run_prepared` plus a map safe to
  show to the approval policy. Preparation may inspect local state to
  resolve names and policy, but must not produce the external effect being
  authorized. Implement `prepare` and `run_prepared` as a matching arity pair.
  """
  @callback prepare(arguments :: map(), Context.t(), keyword()) ::
              {:ok, prepared :: term(), approval_details()} | {:error, term()}

  @doc "Execute exactly the opaque value returned by the matching `prepare` callback."
  @callback run_prepared(prepared :: term(), Context.t(), keyword()) ::
              result()

  @doc "Return `{:unknown, reason}` when dispatch occurred but commit cannot be established. Transport loss and timeouts are not participant declarations of non-commit."
  @callback run(arguments :: map(), Context.t(), keyword()) :: result()

  @optional_callbacks approval: 1,
                      prepare: 3,
                      run_prepared: 3,
                      run: 3

  @doc """
  Declare constant metadata while implementing schema and execution normally.

      use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never

  All three values are explicit. Tools whose metadata depends on options can
  implement the behaviour callbacks directly instead.
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:name, :execution_mode, :approval])

    quote do
      @behaviour Alto.Tool
      @impl true
      def name(_opts \\ []), do: unquote(Keyword.fetch!(opts, :name))
      @impl true
      def execution_mode(_opts \\ []), do: unquote(Keyword.fetch!(opts, :execution_mode))
      @impl true
      def approval(_opts \\ []), do: unquote(Keyword.fetch!(opts, :approval))
    end
  end

  @doc "Build a tool schema whose object parameters reject undeclared fields."
  def object_schema(description, properties, required \\ nil) do
    parameters = %{type: "object", properties: properties, additionalProperties: false}

    parameters =
      if is_nil(required), do: parameters, else: Map.put(parameters, :required, required)

    %{description: description, parameters: parameters}
  end

  def requirement(module, opts) do
    if function_exported?(module, :approval, 1), do: module.approval(opts), else: :required
  end

  @doc "Validate the execution callbacks and select the preparation boundary."
  def preparation(module) do
    Code.ensure_loaded!(module)

    case {function_exported?(module, :prepare, 3), function_exported?(module, :run_prepared, 3)} do
      {true, true} ->
        {:ok, :prepared}

      {false, false} ->
        if function_exported?(module, :run, 3),
          do: {:ok, :none},
          else: {:error, {:invalid_tool, module}}

      _ ->
        {:error, {:incomplete_tool_preparation_callbacks, module}}
    end
  end
end
