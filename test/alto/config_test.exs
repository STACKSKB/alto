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
    File.write!(path, "[max_steps: 0]\n")

    assert {:ok, options} = Config.load(path)

    assert %Alto.Runner.Result{
             status: :error,
             reason: {:invalid_option, :max_steps, 0}
           } = Alto.run("task", options)
  end

  test "loaded loop and tool options drive an actual run", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      "[loop: Alto.rule_loop(steps: [\"configured_echo\"]), " <>
        "tools: [{Alto.ConfigTest.ConfiguredTool, suffix: \"!\"}]]\n"
    )

    assert {:ok, options} = Config.load(path)

    assert %Alto.Runner.Result{status: :ok, output: ["configured!"]} =
             Alto.run(%{"value" => "configured"}, options)
  end

  test "default configuration composes with file overrides and drives a run", %{root: root} do
    defaults = Alto.default_config()
    assert Alto.default_config(run_timeout: 7_200_000)[:run_timeout] == 7_200_000
    path = Path.join(root, "defaults.exs")

    File.write!(
      path,
      "Alto.default_config() |> Keyword.merge(run_timeout: 7200000, " <>
        "loop: Alto.rule_loop(steps: [\"configured_echo\"]), " <>
        "tools: [{Alto.ConfigTest.ConfiguredTool, suffix: \"!\"}])"
    )

    assert {:ok, options} = Config.load(path)
    assert options[:run_timeout] == 7_200_000
    assert options[:provider_timeout] == defaults[:provider_timeout]

    assert %Alto.Runner.Result{status: :ok, output: ["configured!"]} =
             Alto.run(%{"value" => "configured"}, options)

    assert {:ok, budget} = Alto.Runner.Budget.new(options)
    assert Alto.Runner.Budget.remaining(budget) > 7_199_000
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
