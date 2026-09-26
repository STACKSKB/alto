defmodule Alto.Capabilities do
  @moduledoc "Inspect configured extension points without resolving credentials or starting a provider."

  @doc "Whether a module implements every required callback of a behaviour."
  def implements?(module, contract) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        contract.behaviour_info(:callbacks) -- contract.behaviour_info(:optional_callbacks),
        fn
          {name, arity} -> function_exported?(module, name, arity)
        end
      )
  end

  def implements?(_, _), do: false

  @doc "Normalize a module or configured module and validate its callback contract."
  def resolve(module, contract) when is_atom(module), do: resolve({module, []}, contract)

  def resolve({module, options} = spec, contract) do
    if Keyword.keyword?(options) and implements?(module, contract),
      do: {:ok, spec},
      else: {:error, {:invalid_capability, contract, spec}}
  end

  def resolve(spec, contract), do: {:error, {:invalid_capability, contract, spec}}

  @defaults [
    max_steps: 32,
    max_effects: 10_000,
    max_model_requests: 256,
    run_timeout: 900_000,
    max_transcript_bytes: 8_000_000,
    max_tool_result_bytes: 64_000
  ]

  def describe(%Alto.Config{run_options: opts}), do: describe(opts)

  def describe(opts) when is_list(opts) do
    loop = Keyword.get(opts, :loop, Alto.default_loop())
    tools = Enum.map(Keyword.get(opts, :tools, []), &tool/1)

    exposure =
      Enum.map(Keyword.get(opts, :model_tools) || Enum.map(tools, & &1.name), &to_string/1)

    %{
      driver: module_name(loop.driver),
      runner: module_name(Keyword.get(opts, :runner, Alto.Runner.default())),
      tool_execution: tool_execution(loop),
      subagents: subagents(loop.subagents),
      middleware: Enum.map(loop.middleware, &module_name/1),
      provider: module_name(Keyword.get(opts, :provider)),
      approval: module_name(Keyword.get(opts, :approval, Alto.Approvals.DenyAll)),
      tools: Enum.map(tools, &Map.put(&1, :model_visible, &1.name in exposure)),
      context: context(loop.context),
      compaction: compaction(Keyword.get(opts, :compaction, false)),
      limits: Map.new(@defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)
    }
  end

  defp tool_execution(%{driver: Alto.Loops.Default, driver_options: options}) do
    case Keyword.get(options, :tool_execution, :serial) do
      :serial -> %{mode: :serial, max_concurrency: 1}
      {:parallel, limit} -> %{mode: :explicit_batches, max_concurrency: limit}
    end
  end

  defp tool_execution(_), do: %{mode: :loop_defined}

  defp subagents({Alto.Subagents, policy}) do
    %{
      enabled: policy.max_depth > 0,
      max_depth: policy.max_depth,
      max_children: policy.max_children,
      max_concurrency: policy.max_concurrency,
      delegation: :loop_defined
    }
  end

  defp subagents(nil), do: nil
  defp subagents(_), do: :custom

  defp tool(spec) do
    {module, opts} =
      case spec do
        {module, opts} -> {module, opts}
        module -> {module, []}
      end

    Code.ensure_loaded!(module)

    %{
      name: to_string(module.name(opts)),
      module: module_name(module),
      approval: Alto.Tool.requirement(module, opts),
      execution_mode: module.execution_mode(opts),
      prepared: function_exported?(module, :prepare, 3)
    }
  end

  defp context({Alto.Context.Window, window}),
    do: %{
      max_tokens: window.max_tokens,
      reserve_output: window.reserve_output,
      estimator: if(window.estimator, do: "custom", else: "conservative_bytes")
    }

  defp context(nil), do: nil
  defp context(_), do: "custom"
  defp compaction(false), do: false
  defp compaction(true), do: "summary"
  defp compaction(opts), do: opts |> Keyword.get(:strategy, :summary) |> module_name()
  defp module_name(nil), do: nil
  defp module_name({module, _opts}), do: module_name(module)
  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
end
