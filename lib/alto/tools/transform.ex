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

  Native prepared tools keep their own `prepare`/`run_prepared` boundary. A
  native tool that only implements `run` is prepared by this wrapper and its
  transformed arguments are passed to `run_prepared` unchanged.
  """
  @behaviour Alto.Tool

  @type transform :: (map(), Alto.Tool.Context.t() -> map() | {:ok, map()} | {:error, term()})
  @type t :: {module(), keyword()}

  @doc "Return a configured wrapper specification for a tool module or spec."
  @spec wrap(Alto.Tool.spec(), transform()) :: t()
  def wrap(tool, transform) when is_function(transform, 2),
    do: {__MODULE__, [tool: tool, transform: transform]}

  def wrap(tool, opts) when is_list(opts) do
    transform = Keyword.fetch!(opts, :transform)
    wrap(tool, transform)
  end

  @impl true
  def name(opts), do: callback(opts, :name)

  @impl true
  def schema(opts), do: callback(opts, :schema)

  @impl true
  def execution_mode(opts), do: callback(opts, :execution_mode)

  @impl true
  def approval(opts), do: Alto.Tool.requirement(module(opts), inner_opts(opts))

  @impl true
  def prepare(arguments, context, opts) when is_map(arguments) do
    with {:ok, transformed} <- transform(arguments, context, opts),
         {:ok, prepared, details} <- prepare_inner(transformed, context, opts) do
      {:ok, prepared, approval_details(details, transformed)}
    end
  end

  @impl true
  def run_prepared({__MODULE__, :prepared, prepared}, context, opts),
    do: run_inner_prepared(prepared, context, opts)

  def run_prepared({__MODULE__, :raw, arguments}, context, opts),
    do: run_inner_raw(arguments, context, opts)

  def run_prepared(_other, _context, _opts), do: {:error, :invalid_transformed_prepared}

  defp callback(opts, callback),
    do: Alto.Tool.callback(module(opts), callback, inner_opts(opts))

  defp transform(arguments, context, opts) do
    transform = Keyword.fetch!(opts, :transform)

    case transform.(arguments, context) do
      {:ok, transformed} when is_map(transformed) -> {:ok, transformed}
      {:error, _reason} = error -> error
      transformed when is_map(transformed) -> {:ok, transformed}
      other -> {:error, {:invalid_transform_return, other}}
    end
  end

  defp approval_details(details, transformed) when is_map(details),
    do: Map.put(details, "alto_transformed_arguments", transformed)

  defp approval_details(details, _transformed), do: details

  defp prepare_inner(arguments, context, opts) do
    module = module(opts)
    inner_opts = inner_opts(opts)

    case prepared?(module) do
      true ->
        case module.prepare(arguments, context, inner_opts) do
          {:ok, prepared, details} ->
            {:ok, {__MODULE__, :prepared, prepared}, details}

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_tool_prepare_return, other}}
        end

      false ->
        {:ok, {__MODULE__, :raw, arguments}, %{}}
    end
  end

  defp prepared?(module) do
    prepare3? = function_exported?(module, :prepare, 3)
    prepared3? = function_exported?(module, :run_prepared, 3)

    if prepare3? == prepared3?,
      do: prepare3?,
      else: raise(ArgumentError, "wrapped tool has incomplete preparation callbacks")
  end

  defp run_inner_prepared(prepared, context, opts) do
    module = module(opts)
    inner_opts = inner_opts(opts)

    if prepared?(module),
      do: module.run_prepared(prepared, context, inner_opts),
      else: {:error, :invalid_transformed_prepared}
  end

  defp run_inner_raw(arguments, context, opts) do
    module = module(opts)
    inner_opts = inner_opts(opts)

    module.run(arguments, context, inner_opts)
  end

  defp module(opts) do
    {module, _opts} = normalize(Keyword.fetch!(opts, :tool))
    module
  end

  defp inner_opts(opts) do
    {_module, inner_opts} = normalize(Keyword.fetch!(opts, :tool))
    inner_opts
  end

  defp normalize({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}
  defp normalize(other), do: raise(ArgumentError, "invalid wrapped tool #{inspect(other)}")
end
