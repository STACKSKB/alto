defmodule Alto.Tool.Registry do
  @moduledoc false
  # Tool contract validation and model capability projection, independent of execution.
  def build(modules) when is_list(modules) do
    Enum.reduce_while(modules, {:ok, %{}, []}, fn tool_spec, {:ok, tools, definitions} ->
      with {:ok, module, tool_opts} <- normalize_tool(tool_spec),
           name when is_atom(name) <- module.name(tool_opts),
           schema when is_map(schema) <- module.schema(tool_opts),
           {:ok, preparation} <- Alto.Tool.preparation(module),
           string_name = Atom.to_string(name),
           true <-
             not Map.has_key?(tools, string_name) or {:error, {:duplicate_tool, string_name}},
           mode when mode in [:parallel, :exclusive] <-
             module.execution_mode(tool_opts),
           approval when approval in [:never, :required] <-
             Alto.Tool.requirement(module, tool_opts) do
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
          execution_mode: mode,
          approval: approval,
          preparation: preparation
        }

        {:cont, {:ok, Map.put(tools, string_name, tool), [definition | definitions]}}
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
end
