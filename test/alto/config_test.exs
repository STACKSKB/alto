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

  test "rejects duplicate options" do
    assert_raise ArgumentError, ~r/options must be unique/, fn ->
      Config.new(max_steps: 1, max_steps: 2)
    end
  end

  test "rejects duplicate TUI options" do
    assert_raise ArgumentError, ~r/TUI configuration options must be unique/, fn ->
      Config.new(tui: [approval_auto_open: true, approval_auto_open: false])
    end
  end

  test "rejects listener modules without start_link" do
    assert_raise NimbleOptions.ValidationError, fn ->
      Config.new(listeners: [{String, []}])
    end
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
