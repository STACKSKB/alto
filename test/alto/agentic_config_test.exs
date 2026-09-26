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

  test "coding profile exposes bounded delegation and hides the direct Codex tool" do
    assert {:ok, config} = Alto.Config.load(Path.expand("../../alto.agentic.exs", __DIR__))
    opts = Alto.Config.run_options(config)

    assert {:ok, %{max_depth: 1, max_children: 4, max_concurrency: 2, sessions: :separate}} =
             Alto.Subagents.Policy.resolve(opts[:loop].subagents)

    assert :list_agent_models in opts[:model_tools]
    assert :spawn_agents in opts[:model_tools]
    refute :codex_agent in opts[:model_tools]

    assert {Alto.Tools.SpawnAgents, []} in opts[:tools]
    assert {:ok, _, _} = Alto.Tool.Registry.build(opts[:tools])
  end

  test "request diagnostics are explicitly enabled" do
    System.put_env("ALTO_REQUEST_DIAGNOSTICS", "1")
    assert {:ok, config} = Alto.Config.load(Path.expand("../../alto.agentic.exs", __DIR__))
    assert [profile] = Alto.Config.run_options(config)[:provider_profiles]
    assert {Alto.Providers.Observe, _} = profile[:provider]
  end
end
