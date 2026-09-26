defmodule Alto.ConfigTest do
  use ExUnit.Case, async: true

  alias Alto.Config

  defmodule ConfiguredTool do
    use Alto.Tool, name: :configured_echo, execution_mode: :parallel, approval: :never

    def schema(_opts),
      do: %{description: "configured echo", parameters: %{type: "object"}}

    def run(%{"value" => value}, _context, opts),
      do: {:ok, value <> Keyword.fetch!(opts, :suffix)}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads execution limits and defers their validation to the runner", %{root: root} do
    path = Path.join(root, "config.exs")
    File.write!(path, "Alto.Config.new(max_steps: 0)\n")

    assert {:ok, config} = Config.load(path)

    assert %Alto.Runner.Result{
             status: :error,
             reason: {:invalid_option, :max_steps, 0}
           } = Alto.run("task", Config.run_options(config))
  end

  test "requires only a keyword-list container" do
    assert_raise ArgumentError, ~r/keyword list/, fn ->
      Config.new([:not_a_pair])
    end
  end

  test "loaded loop and tool options drive an actual run", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      "Alto.Config.new(loop: Alto.rule_loop(steps: [\"configured_echo\"]), " <>
        "tools: [{Alto.ConfigTest.ConfiguredTool, suffix: \"!\"}])\n"
    )

    assert {:ok, config} = Config.load(path)

    assert %Alto.Runner.Result{status: :ok, output: ["configured!"]} =
             Alto.run(%{"value" => "configured"}, Config.run_options(config))
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
