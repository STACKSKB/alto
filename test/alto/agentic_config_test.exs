defmodule Alto.AgenticConfigTest do
  use ExUnit.Case, async: true

  test "the database-free coding profile loads as ordinary Alto configuration" do
    path = Path.expand("../../alto.agentic.exs", __DIR__)
    assert {:ok, config} = Alto.Config.load(path)
    opts = Alto.Config.run_options(config)

    assert Keyword.fetch!(opts, :sessions) == true
    assert Keyword.fetch!(opts, :project_instructions) == :auto
    assert Keyword.fetch!(opts, :compaction)[:strategy] == :handoff

    assert [profile] = Keyword.fetch!(opts, :provider_profiles)
    assert profile[:id] == "openrouter"
    assert profile[:label] == "OpenRouter"

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
