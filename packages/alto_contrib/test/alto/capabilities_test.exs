defmodule Alto.CapabilitiesTest do
  use ExUnit.Case, async: true

  test "inspection excludes secrets and reflects option-based tools and hidden capabilities" do
    config =
      [
        provider: {Alto.Contrib.Providers.OpenAICompatible, api_key: "private-key"},
        tools: [
          {Alto.Contrib.Tools.MCP, name: :custom, server: [command: "must-not-start"]},
          Alto.Contrib.Tools.ReadFile
        ],
        model_tools: [:read_file],
        max_effects: 25
      ]

    description = Alto.Capabilities.describe(config)

    assert [%{name: "custom", model_visible: false, approval: :required}, %{model_visible: true}] =
             description.tools

    assert description.limits.max_effects == 25
    assert description.tool_execution == %{mode: :serial, max_concurrency: 1}
    assert description.subagents.enabled == false
    assert description.subagents.max_depth == 0
    assert description.subagents.max_concurrency == 1
    refute JSON.encode!(description) =~ "private-key"
    refute JSON.encode!(description) =~ "must-not-start"
  end
end
