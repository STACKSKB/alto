defmodule Alto.Tools.Transform do
  @moduledoc """
  Prepare an invocation after applying a deterministic argument transform.

  `wrap/2` returns a normal Alto tool specification:

      Alto.Tools.Transform.wrap(Alto.Tools.ReadFile, fn args, context ->
        Map.put(args, "path", Path.expand(args["path"], context.cwd))
      end)

  The wrapped tool keeps its name, schema, approval requirement, and execution
  mode. The transform runs once at preparation time. Its result is frozen in
  the opaque prepared value, so approval and execution cannot cause a second
  transform or resolve a different value after approval.

  Prepared tools keep their own `prepare`/`run` boundary. Tools without
  preparation receive the transformed arguments through `run` unchanged.
  """
  @behaviour Alto.Tool

  @type transform :: (map(), Alto.Tool.Context.t() -> map() | {:ok, map()} | {:error, term()})
  @type t :: {module(), keyword()}

  @doc "Return a configured wrapper specification for a tool module or spec."
  @spec wrap(Alto.Tool.spec(), transform()) :: t()
  def wrap(tool, transform) when is_function(transform, 2),
    do: {__MODULE__, [tool: tool, transform: transform]}

  @impl true
  def name(opts), do: callback(opts, :name)

  @impl true
  def schema(opts), do: callback(opts, :schema)

  @impl true
  def execution_mode(opts), do: callback(opts, :execution_mode)

  @impl true
  def approval(opts) do
    {module, inner_opts} = inner_tool(opts)
    Alto.Tool.requirement(module, inner_opts)
  end

  @impl true
  def prepare(arguments, context, opts) when is_map(arguments) do
    {module, inner_opts} = inner_tool(opts)

    with {:ok, transformed} <- transform(arguments, context, opts),
         {:ok, prepared, details} <- Alto.Tool.prepare(module, transformed, context, inner_opts) do
      {:ok, {__MODULE__, prepared}, Map.put(details, "alto_transformed_arguments", transformed)}
    end
  end

  @impl true
  def run({__MODULE__, value}, context, opts) do
    {module, inner_opts} = inner_tool(opts)
    module.run(value, context, inner_opts)
  end

  def run(_other, _context, _opts), do: {:error, :invalid_transformed_prepared}

  defp callback(opts, callback) do
    {module, inner_opts} = inner_tool(opts)
    apply(module, callback, [inner_opts])
  end

  defp transform(arguments, context, opts) do
    transform = Keyword.fetch!(opts, :transform)

    case transform.(arguments, context) do
      {:ok, transformed} when is_map(transformed) -> {:ok, transformed}
      {:error, _reason} = error -> error
      transformed when is_map(transformed) -> {:ok, transformed}
      other -> {:error, {:invalid_transform_return, other}}
    end
  end

  defp inner_tool(opts), do: normalize(Keyword.fetch!(opts, :tool))

  defp normalize({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}
  defp normalize(other), do: raise(ArgumentError, "invalid wrapped tool #{inspect(other)}")
end
