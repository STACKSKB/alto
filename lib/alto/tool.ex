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

  A prepared tool returns an opaque value for `run` plus a map safe to
  show to the approval policy. Preparation may inspect local state to
  resolve names and policy, but must not produce the external effect being
  authorized. Without this callback, `run` receives the original arguments.
  """
  @callback prepare(arguments :: map(), Context.t(), keyword()) ::
              {:ok, prepared :: term(), approval_details()} | {:error, term()}

  @doc "Execute the prepared value, or original arguments when preparation is omitted. Return `{:unknown, reason}` when dispatch occurred but commit cannot be established."
  @callback run(value :: term(), Context.t(), keyword()) :: result()

  @optional_callbacks approval: 1, prepare: 3

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

  @doc "Prepare a tool input and validate its return contract without executing it."
  def prepare(module, arguments, context, opts) do
    Code.ensure_loaded!(module)

    with true <- function_exported?(module, :run, 3) or {:error, {:invalid_tool, module}} do
      result =
        if function_exported?(module, :prepare, 3),
          do: module.prepare(arguments, context, opts),
          else: {:ok, arguments, %{}}

      case result do
        {:ok, _value, details} when is_map(details) -> result
        {:ok, _value, details} -> {:error, {:invalid_approval_details, details}}
        {:error, _} -> result
        other -> {:error, {:invalid_tool_prepare_return, other}}
      end
    end
  end
end
