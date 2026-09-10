defmodule Alto.ConfigTest do
  use ExUnit.Case, async: true

  alias Alto.Config

  setup do
    root = Path.join(System.tmp_dir!(), "alto-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads a compiled Elixir configuration value", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      "Alto.Config.new(max_steps: 7, tools: [], loop: Alto.chat_loop())\n"
    )

    assert {:ok, config} = Config.load(path)

    assert Config.run_options(config) == [
             max_steps: 7,
             tools: [],
             loop: Alto.chat_loop()
           ]
  end

  test "rejects unknown and duplicate options" do
    assert_raise ArgumentError, ~r/unknown Alto configuration options/, fn ->
      Config.new(unknown: true)
    end

    assert_raise ArgumentError, ~r/options must be unique/, fn ->
      Config.new(max_steps: 1, max_steps: 2)
    end
  end

  test "accepts the durability feature options" do
    config = Config.new(compaction: true, provider_retries: 3)

    assert Config.run_options(config) == [compaction: true, provider_retries: 3]
  end

  test "validates TUI options" do
    tui = [
      type_to_compose: false,
      narrow_context: :drawer,
      narrow_context_width: 68,
      narrow_context_fullscreen_below: 64,
      approval_auto_open: false
    ]

    config = Config.new(tui: tui)
    assert Config.run_options(config)[:tui] == tui

    assert_raise ArgumentError, ~r/unknown Alto TUI configuration options/, fn ->
      Config.new(tui: [mystery: true])
    end

    assert_raise ArgumentError, ~r/:type_to_compose must be a boolean/, fn ->
      Config.new(tui: [type_to_compose: :sometimes])
    end

    assert_raise ArgumentError, ~r/:narrow_context must be/, fn ->
      Config.new(tui: [narrow_context: :bottom_sheet])
    end

    assert_raise ArgumentError, ~r/:narrow_context_width must be/, fn ->
      Config.new(tui: [narrow_context_width: 20])
    end
  end

  test "accepts the integration-host options" do
    config =
      Config.new(
        queue: [id: "jobs"],
        runs: %{"job" => [tools: []]},
        model_tools: ["echo"]
      )

    assert Config.run_options(config)[:queue] == [id: "jobs"]
    assert Config.run_options(config)[:runs] == %{"job" => [tools: []]}
    assert Config.run_options(config)[:model_tools] == ["echo"]
  end

  test "accepts the served-sessions options" do
    config = Config.new(sessions: true)
    assert Config.run_options(config)[:sessions] == true

    config = Config.new(sessions: [session_dir: "/tmp/alto-sess"], session_dir: "/tmp/alto-sess")
    assert Config.run_options(config)[:sessions] == [session_dir: "/tmp/alto-sess"]
  end

  test "distinguishes the default provider from an explicit providerless profile" do
    assert Config.provider_mode(Config.new()) == :default
    assert Config.provider_mode(Config.new(provider: nil)) == :none

    provider = {Alto.Providers.OpenAICompatible, model: "configured"}
    assert Config.provider_mode(Config.new(provider: provider)) == {:configured, provider}
  end

  test "reports evaluation failures and invalid return values", %{root: root} do
    broken = Path.join(root, "broken.exs")
    invalid = Path.join(root, "invalid.exs")
    File.write!(broken, "raise \"broken config\"\n")
    File.write!(invalid, "%{not: :config}\n")

    assert {:error, {:config_load_failed, ^broken, message}} = Config.load(broken)
    assert message =~ "broken config"

    assert {:error, {:invalid_config_return, ^invalid}} = Config.load(invalid)
  end
end
