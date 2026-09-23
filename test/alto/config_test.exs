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
    assert_raise NimbleOptions.ValidationError, ~r/unknown options.*unknown/, fn ->
      Config.new(unknown: true)
    end

    assert_raise ArgumentError, ~r/options must be unique/, fn ->
      Config.new(max_steps: 1, max_steps: 2)
    end
  end

  test "validates TUI options" do
    assert_raise NimbleOptions.ValidationError, ~r/unknown options.*mystery/, fn ->
      Config.new(tui: [mystery: true])
    end

    assert_raise NimbleOptions.ValidationError, ~r/:type_to_compose.*boolean/, fn ->
      Config.new(tui: [type_to_compose: :sometimes])
    end

    assert_raise NimbleOptions.ValidationError, ~r/:narrow_context/, fn ->
      Config.new(tui: [narrow_context: :bottom_sheet])
    end

    assert_raise NimbleOptions.ValidationError, ~r/:narrow_context_width/, fn ->
      Config.new(tui: [narrow_context_width: 20])
    end
  end

  test "TUI schemas retain integer bounds and reject duplicate keys" do
    for value <- [39, 101, 40.0, nil] do
      assert_raise NimbleOptions.ValidationError,
                   ~r/:narrow_context_width/,
                   fn ->
                     Config.new(tui: [narrow_context_width: value])
                   end
    end

    assert_raise ArgumentError, ~r/TUI configuration options must be unique/, fn ->
      Config.new(tui: [approval_auto_open: true, approval_auto_open: false])
    end
  end

  test "rejects invalid host shapes at the configuration boundary" do
    for options <- [
          [runs: []],
          [runs: %{job: []}],
          [runs: %{"job" => ["not a keyword"]}],
          [sessions: "yes"],
          [sessions: [unknown: true]],
          [sessions: [session_dir: 42]],
          [queue: :yes],
          [listeners: :none],
          [listeners: [{String, []}]],
          [listeners: [{Alto.Listeners.WebServer, %{port: 4747}}]]
        ] do
      assert_raise NimbleOptions.ValidationError, fn -> Config.new(options) end
    end
  end

  test "preserves configured host options and explicit opt-outs" do
    options = [
      runs: %{"job" => [max_steps: 2]},
      sessions: nil,
      queue: nil,
      listeners: [
        {Alto.Listeners.UnixSocket, path: "/tmp/alto.sock"},
        {Alto.Listeners.WebServer, port: 0},
        {Alto.Listeners.Webhook, port: 0, endpoints: []}
      ]
    ]

    assert Config.run_options(Config.new(options)) == options
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
