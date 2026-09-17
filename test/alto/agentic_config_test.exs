defmodule Alto.AgenticConfigTest do
  use ExUnit.Case, async: false

  setup do
    diagnostics = System.get_env("ALTO_REQUEST_DIAGNOSTICS")
    System.delete_env("ALTO_REQUEST_DIAGNOSTICS")

    on_exit(fn ->
      if diagnostics,
        do: System.put_env("ALTO_REQUEST_DIAGNOSTICS", diagnostics),
        else: System.delete_env("ALTO_REQUEST_DIAGNOSTICS")
    end)
  end

  test "request diagnostics are explicitly enabled" do
    System.put_env("ALTO_REQUEST_DIAGNOSTICS", "1")
    assert {:ok, config} = Alto.Config.load(Path.expand("../../alto.agentic.exs", __DIR__))
    assert [profile] = Alto.Config.run_options(config)[:provider_profiles]
    assert {Alto.Providers.Observe, _} = profile[:provider]
  end

  test "the database-free coding profile loads as ordinary Alto configuration" do
    path = Path.expand("../../alto.agentic.exs", __DIR__)
    assert {:ok, config} = Alto.Config.load(path)
    opts = Alto.Config.run_options(config)

    assert Keyword.fetch!(opts, :sessions) == true
    assert Keyword.fetch!(opts, :session_history) == :settled
    assert Keyword.fetch!(opts, :project_instructions) == :auto
    assert Keyword.fetch!(opts, :compaction)[:strategy] == {Alto.Context.Reducers.Handoff, []}
    assert Keyword.fetch!(opts, :compaction)[:max_compactions] == 8
    assert Keyword.fetch!(opts, :loop).driver_options[:tool_execution] == {:parallel, 4}
    assert Keyword.fetch!(opts, :loop).context.compact_at == 0.85
    assert Keyword.fetch!(opts, :loop).subagents.max_depth == 0

    assert [profile] = Keyword.fetch!(opts, :provider_profiles)
    assert profile[:id] == "openrouter"
    assert profile[:label] == "OpenRouter"
    assert {Alto.Providers.OpenAICompatible, _} = profile[:provider]

    names =
      Enum.map(Keyword.fetch!(opts, :tools), fn
        {module, tool_opts} ->
          Code.ensure_loaded?(module)
          if function_exported?(module, :name, 1), do: module.name(tool_opts), else: module.name()

        module ->
          module.name()
      end)

    assert :git_inspect in names
    assert :git_mutate in names
    assert :run_command in names
    refute Enum.any?(names, &(&1 in [:ecto, :oban]))
  end
end
