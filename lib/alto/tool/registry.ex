defmodule Alto.Tool.Registry do
  @moduledoc false
  # Trusted tool registration and model capability projection.
  def build(modules, child_limits \\ nil)

  def build(modules, child_limits) when is_list(modules) do
    Alto.Result.reduce(modules, %{}, fn tool_spec, tools ->
      {module, tool_opts} = Alto.Capabilities.normalize(tool_spec)
      transforms = tool_opts[:alto_transform] || []
      tool_opts = Alto.Tool.configure(module, tool_opts)
      string_name = module.name(tool_opts) |> Atom.to_string()
      operation = Alto.Tool.runtime_operation(module, tool_opts)
      schema = module.schema(schema_opts(operation, tool_opts, child_limits))
      true = is_map(schema)
      mode = module.execution_mode(tool_opts)
      true = mode in [:parallel, :exclusive]
      approval = Alto.Tool.requirement(module, tool_opts)
      true = approval in [:never, :required]

      if Map.has_key?(tools, string_name) do
        {:error, {:duplicate_tool, string_name}}
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
          transforms: transforms,
          execution_mode: mode,
          approval: approval,
          runtime_operation: operation,
          definition: definition
        }

        {:ok, Map.put(tools, string_name, tool)}
      end
    end)
  end

  defp schema_opts(operation, opts, %{max_children: max_children})
       when operation in [:spawn_agents, :start_agents],
       do: Keyword.put(opts, :max_children, max_children)

  defp schema_opts(_module, opts, _child_limits), do: opts

  # Runtime capabilities (`:tools`) vs model exposure (`:model_tools`).
  # Every registered tool is invokable via `{:invoke_tool, call}`; only the
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
  # Provider definitions are emitted in name order, independent of host spec order.
  def expose(tool_map, names, parent_exposure) do
    registered = MapSet.new(Map.keys(tool_map))
    requested = MapSet.new(names || Map.keys(tool_map), &to_string/1)

    case requested |> MapSet.difference(registered) |> Enum.sort() do
      [] ->
        effective = MapSet.intersection(requested, parent_exposure || registered)
        definitions = effective |> Enum.sort() |> Enum.map(&tool_map[&1].definition)
        {:ok, definitions, effective}

      [missing | _] ->
        {:error, {:unknown_model_tool, missing}}
    end
  end
end
