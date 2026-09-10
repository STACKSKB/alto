defmodule Alto.Tool.Registry do
  @moduledoc false
  # Tool contract validation and model capability projection, independent of execution.
  def build(modules) when is_list(modules) do
    Enum.reduce_while(modules, {:ok, %{}, []}, fn tool_spec, {:ok, tools, definitions} ->
      with {:ok, module, tool_opts} <- normalize_tool(tool_spec),
           name when is_atom(name) <- Alto.Tool.callback(module, :name, tool_opts),
           schema when is_map(schema) <- Alto.Tool.callback(module, :schema, tool_opts),
           {:ok, preparation} <- tool_preparation(module, tool_opts),
           :ok <- validate_tool_execution(module, tool_opts, preparation) do
        string_name = Atom.to_string(name)

        if Map.has_key?(tools, string_name) do
          {:halt, {:error, {:duplicate_tool, string_name}}}
        else
          definition = %{
            "type" => "function",
            "function" =>
              schema
              |> Map.new(fn {key, value} -> {to_string(key), value} end)
              |> Map.put("name", string_name)
          }

          tool = %{
            module: module,
            opts: tool_opts,
            execution_mode: Alto.Tool.callback(module, :execution_mode, tool_opts),
            approval: Alto.Tool.requirement(module, tool_opts),
            preparation: preparation
          }

          if tool.execution_mode in [:parallel, :exclusive] and
               tool.approval in [:never, :required] do
            {:cont, {:ok, Map.put(tools, string_name, tool), [definition | definitions]}}
          else
            {:halt, {:error, {:invalid_tool, module}}}
          end
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _other -> {:halt, {:error, {:invalid_tool, tool_spec}}}
      end
    end)
    |> case do
      {:ok, tools, definitions} -> {:ok, tools, Enum.reverse(definitions)}
      error -> error
    end
  rescue
    error -> {:error, {:invalid_tool, error}}
  end

  def build(other), do: {:error, {:invalid_tools, other}}

  # Runtime capabilities (`:tools`) vs model exposure (`:model_tools`).
  # Every registered tool is invokable via `Effect.invoke_tool/1`; only the
  # projected subset reaches the provider's function definitions, so a
  # deterministic loop can hold application capabilities without showing
  # them to the model. `nil` (default) exposes everything, preserving
  # existing compositions.
  #
  # Delegation: the effective exposure is carried into child runs and
  # intersected with inherited or narrowed capabilities, so a child can never
  # widen what its parent hid. `parent_exposure` is the parent run's
  # effective `MapSet` (or `nil` for a root run). A `nil` `model_tools`
  # request means "all of this run's registered tools"; an explicit list
  # (including `[]`) narrows further. Deterministic-only registration is
  # `tools: [...]` with `model_tools: []`: full runtime authority via
  # `invoke_tool`, zero provider-visible schemas.
  def expose(definitions, tool_map, model_tools_opt, parent_exposure) do
    with {:ok, requested} <- requested_exposure(tool_map, model_tools_opt),
         {:ok, effective} <- intersect_exposure(requested, parent_exposure) do
      filtered =
        Enum.filter(definitions, fn %{"function" => %{"name" => name}} ->
          MapSet.member?(effective, name)
        end)

      {:ok, filtered, effective}
    end
  end

  defp requested_exposure(tool_map, nil), do: {:ok, MapSet.new(Map.keys(tool_map))}

  defp requested_exposure(tool_map, names) when is_list(names) do
    wanted =
      Enum.map(names, fn
        name when is_atom(name) -> Atom.to_string(name)
        name when is_binary(name) -> name
        other -> {:invalid, other}
      end)

    if Enum.any?(wanted, &match?({:invalid, _}, &1)) do
      {:error, {:invalid_model_tools, names}}
    else
      unknown = Enum.reject(wanted, &Map.has_key?(tool_map, &1))

      case unknown do
        [] -> {:ok, MapSet.new(wanted)}
        [missing | _] -> {:error, {:unknown_model_tool, missing}}
      end
    end
  end

  defp requested_exposure(_tool_map, other), do: {:error, {:invalid_model_tools, other}}

  defp intersect_exposure(requested, nil), do: {:ok, requested}

  defp intersect_exposure(requested, %MapSet{} = parent),
    do: {:ok, MapSet.intersection(parent, requested)}

  defp intersect_exposure(_requested, other),
    do: {:error, {:invalid_parent_model_tools, other}}

  defp normalize_tool({module, opts}) when is_atom(module) and is_list(opts),
    do: {:ok, module, opts}

  defp normalize_tool(module) when is_atom(module), do: {:ok, module, []}
  defp normalize_tool(other), do: {:error, {:invalid_tool, other}}

  defp tool_preparation(module, opts) do
    prepare2? = function_exported?(module, :prepare, 2)
    prepared2? = function_exported?(module, :run_prepared, 2)
    prepare3? = function_exported?(module, :prepare, 3)
    prepared3? = function_exported?(module, :run_prepared, 3)
    any? = prepare2? or prepared2? or prepare3? or prepared3?

    cond do
      prepare2? != prepared2? or prepare3? != prepared3? ->
        {:error, {:incomplete_tool_preparation_callbacks, module}}

      opts == [] and prepare2? and prepared2? ->
        {:ok, :arity2}

      prepare3? and prepared3? ->
        {:ok, :arity3}

      not any? ->
        {:ok, :none}

      true ->
        {:error, {:tool_does_not_accept_options, module}}
    end
  end

  defp validate_tool_execution(module, opts, :none) do
    arity = if opts == [], do: 2, else: 3

    if function_exported?(module, :run, arity) do
      :ok
    else
      {:error, {:tool_does_not_accept_options, module}}
    end
  end

  defp validate_tool_execution(_module, _opts, preparation)
       when preparation in [:arity2, :arity3],
       do: :ok
end
