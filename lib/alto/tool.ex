defmodule Alto.Tool do
  @moduledoc "Contract for model-facing tools. Tools do not share the provider contract."

  @context_fields [
    :session_id,
    :cwd,
    :metadata,
    :agent_identity,
    :messaging,
    :input,
    :input_reader,
    :messaging_tools,
    :budget
  ]
  @type context :: %{
          required(:session_id) => String.t(),
          required(:cwd) => String.t(),
          optional(atom()) => term()
        }

  @doc "Project runtime-issued tool fields; provider configuration never enters the context."
  def context(run), do: Map.new(@context_fields, &{&1, Map.get(run, &1)})

  @type execution_mode :: :parallel | :exclusive
  @type approval_requirement :: :never | :required
  @type approval_details :: map()
  @type options :: keyword() | map()
  @type spec :: module() | {module(), options()}
  @type result :: {:ok, term()} | {:error, term()} | {:unknown, term()}

  @doc "Trusted defaults for tools receiving canonical map options. Host overrides are merged before registration or standalone execution."
  @callback options() :: map()
  @callback name(options()) :: atom()
  @callback schema(options()) :: map()
  @callback execution_mode(options()) :: execution_mode()

  @doc """
  Declare how this tool is treated by the approval boundary.

  `:required` (the default for tools that omit this callback) routes every
  invocation through the configured approval policy. `:never` is an absolute
  opt-out: no approval policy is consulted and none can claw back a specific
  invocation once the tool has declared itself exempt. The tool's author is
  therefore the trust boundary for any `:never` tool, so reserve `:never` for
  tools that are genuinely side-effect-free.
  """
  @callback approval(options()) :: approval_requirement()

  @doc """
  Validate and resolve an invocation before approval without performing it.

  A prepared tool returns an opaque value for `run` plus a map safe to
  show to the approval policy. Preparation may inspect local state to
  resolve names and policy, but must not produce the external effect being
  authorized. Without this callback, `run` receives arguments with contract defaults.
  """
  @callback prepare(arguments :: map(), Alto.Tool.context(), options()) ::
              {:ok, prepared :: term(), approval_details()} | {:error, term()}

  @doc "Execute the prepared value, or validated arguments when preparation is omitted. Return `{:unknown, reason}` when dispatch occurred but commit cannot be established."
  @callback run(value :: term(), Alto.Tool.context(), options()) :: result()

  @doc "Optional built-in argument contract. Tools opting in validate at `Alto.Tool.prepare/4`; their prepare/run functions are callbacks receiving validated or frozen input."
  @callback arguments(options()) :: {String.t(), keyword()}
  @optional_callbacks approval: 1, prepare: 3, arguments: 1, options: 0

  @doc """
  Declare constant metadata while implementing schema and execution normally.

      use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never

  All three values are explicit. Tools whose metadata depends on options can
  implement the behaviour callbacks directly instead.
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:name, :execution_mode, :approval, :arguments])

    schema =
      if Keyword.get(opts, :arguments, false) do
        quote do
          @impl true
          def schema(opts \\ []),
            do: Alto.Tool.Arguments.schema(arguments(Alto.Tool.configure(__MODULE__, opts)))
        end
      end

    quote do
      unquote(schema)
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

  @doc "Apply a host-side input transform once before validation and preparation. Nested transforms run outermost first."
  def transform(spec, transform) when is_function(transform, 2) do
    {module, opts} = Alto.Capabilities.normalize(spec)
    transforms = [transform | opts[:alto_transform] || []]
    opts = put_in(opts[:alto_transform], transforms)
    {module, opts}
  end

  def configure(module, opts) do
    opts = elem(Access.pop(opts, :alto_transform), 1)
    Code.ensure_loaded!(module)

    if is_map(opts) or not function_exported?(module, :options, 0),
      do: opts,
      else: Map.merge(module.options(), Map.new(opts))
  end

  def requirement(module, opts) do
    if function_exported?(module, :approval, 1), do: module.approval(opts), else: :required
  end

  @doc "Prepare a tool input and validate its return contract without executing it."
  def prepare(module, arguments, context, opts \\ [], transforms \\ nil) do
    transforms = transforms || opts[:alto_transform] || []
    opts = configure(module, opts)

    with {:ok, transformed} <- transform_arguments(arguments, context, transforms),
         {:ok, arguments} <- validate_arguments(module, transformed, opts) do
      result =
        if function_exported?(module, :prepare, 3),
          do: module.prepare(arguments, context, opts),
          else: {:ok, arguments, %{}}

      case result do
        {:ok, value, details} when is_map(details) ->
          details =
            if transforms == [],
              do: details,
              else: Map.put(details, "alto_transformed_arguments", transformed)

          {:ok, value, details}

        {:error, _} ->
          result
      end
    end
  end

  @doc "Prepare and execute in the caller. Runner hosts separately supply approval, supervision, and cancellation."
  def run(module, arguments, context, opts \\ []) do
    transforms = opts[:alto_transform] || []
    opts = configure(module, opts)

    with {:ok, prepared, _details} <- prepare(module, arguments, context, opts, transforms),
         do: module.run(prepared, context, opts)
  end

  defp transform_arguments(arguments, context, transforms) do
    Alto.Result.reduce(transforms, arguments, fn transform, arguments ->
      case transform.(arguments, context) do
        {:ok, transformed} when is_map(transformed) -> {:ok, transformed}
        transformed when is_map(transformed) -> {:ok, transformed}
        {:error, _} = error -> error
        other -> {:error, {:invalid_transform_return, other}}
      end
    end)
  end

  defp validate_arguments(module, arguments, opts) do
    if function_exported?(module, :arguments, 1),
      do: Alto.Tool.Arguments.validate(arguments, elem(module.arguments(opts), 1)),
      else: {:ok, arguments}
  rescue
    error in NimbleOptions.ValidationError -> {:error, error}
  end
end
