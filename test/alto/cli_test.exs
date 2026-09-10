defmodule Alto.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, _opts), do: {:ok, %{message: "configured", tool_calls: []}}
  end

  defmodule NoToolsProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(%{tools: []}, _sink, _opts),
      do: {:ok, %{message: "tool-free", tool_calls: []}}

    def stream(request, _sink, _opts), do: {:error, {:unexpected_tools, request.tools}}
  end

  defmodule StreamingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, sink, _opts) do
      sink.(Alto.Event.live(:model_delta, %{text: "streamed"}))
      {:ok, %{message: "streamed", tool_calls: []}}
    end
  end

  defmodule DefaultToolsProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(%{tools: tools}, _sink, _opts) do
      names = Enum.map(tools, &get_in(&1, ["function", "name"]))

      if names == ["list_files", "read_file", "search_files"] do
        {:ok, %{message: "search-ready", tool_calls: []}}
      else
        {:error, {:unexpected_tools, names}}
      end
    end
  end

  defmodule ModelReportingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      {:ok, %{message: "model=#{Keyword.fetch!(opts, :model)}", tool_calls: []}}
    end
  end

  defmodule ProviderlessTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :providerless_echo

    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(arguments, _context), do: {:ok, arguments}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "fails immediately with useful feedback when no task is provided" do
    assert capture_io("", fn ->
             assert {:error, message} = Alto.CLI.run([])
             assert message =~ "no task provided"
             assert message =~ "arguments or pipe one on stdin"
           end) == ""
  end

  test "setup requires an interactive terminal" do
    assert {:error, "--setup requires an interactive terminal"} = Alto.CLI.run(["--setup"])
  end

  test "rejects conflicting command execution modes before starting a provider" do
    assert {:error, "choose either --allow-command or --sandbox-command, not both"} =
             Alto.CLI.run([
               "--no-config",
               "--model",
               "unused",
               "--allow-command",
               "--sandbox-command",
               "task"
             ])
  end

  test "requires sandbox mode before network inheritance can be enabled" do
    assert {:error, "--allow-command-network requires --sandbox-command"} =
             Alto.CLI.run([
               "--no-config",
               "--model",
               "unused",
               "--allow-command-network",
               "task"
             ])
  end

  test "runs without a model flag when compiled configuration supplies a provider", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        tools: [],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "answer from config"])
           end) == "configured\n"
  end

  test "rejects conflicting configuration switches" do
    assert {:error, "choose either --config or --no-config, not both"} =
             Alto.CLI.run(["--config", "unused.exs", "--no-config", "task"])
  end

  test "explicit tool flags override configured tools", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.NoToolsProvider,
        tools: [Alto.Tools.ListFiles],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "--no-tools", "ignore tools"])
           end) == "tool-free\n"
  end

  test "default CLI tools include bounded repository search", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.DefaultToolsProvider,
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "inspect repository"])
           end) == "search-ready\n"
  end

  test "does not repeat a final response that was already streamed", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.StreamingProvider,
        tools: [],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "stream once"])
           end) == "streamed\n"
  end

  test "a model flag overrides only the configured provider's model", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: {Alto.CLITest.ModelReportingProvider, model: "configured-model"},
        tools: [],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok =
                      Alto.CLI.run(["--config", path, "--model", "override-model", "task"])
           end) == "model=override-model\n"
  end

  test "a configured provider keeps its model when no model flag is given", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: {Alto.CLITest.ModelReportingProvider, model: "configured-model"},
        tools: [],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "task"])
           end) == "model=configured-model\n"
  end

  test "an explicitly providerless deterministic run does not invoke onboarding", %{
    root: root
  } do
    path = Path.join(root, "providerless.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: nil,
        loop: Alto.rule_loop(steps: ["providerless_echo"]),
        tools: [Alto.CLITest.ProviderlessTool],
        system_prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok =
                      Alto.CLI.run([
                        "--config",
                        path,
                        "--no-session",
                        ~s({"value":"without credentials"})
                      ])
           end) == "\n"
  end

  test "an omitted provider keeps the default onboarding path" do
    assert {:error, message} = Alto.CLI.run(["--no-config", "model task"])
    assert message =~ "OpenRouter API key required"
  end

  test "a providerless server profile with a named Rule run stays alive without credentials", %{
    root: root
  } do
    path = Path.join(root, "server-providerless.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: nil,
        system_prompt: nil,
        listeners: [],
        runs: %{
          "rule" => [
            loop: Alto.rule_loop(steps: ["providerless_echo"]),
            tools: [Alto.CLITest.ProviderlessTool]
          ]
        }
      )
      """
    )

    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:serve_result, Alto.CLI.run(["--config", path, "--serve"])})
      end)

    refute_receive {:serve_result, _result}, 300
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
  end

  test "a base-url flag rebuilds the provider instead of using the configured one", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.ModelReportingProvider,
        tools: [],
        system_prompt: nil
      )
      """
    )

    previous = System.get_env("ALTO_MODEL")
    System.delete_env("ALTO_MODEL")

    try do
      assert {:error, "set --model or ALTO_MODEL"} =
               Alto.CLI.run(["--config", path, "--base-url", "https://unit.test/v1", "task"])
    after
      if previous, do: System.put_env("ALTO_MODEL", previous)
    end
  end

  test "reports an invalid configuration return", %{root: root} do
    path = Path.join(root, "config.exs")
    File.write!(path, ":not_a_config\n")

    assert {:error, message} = Alto.CLI.run(["--config", path, "task"])
    assert message =~ "must return %Alto.Config{}"
  end

  test "serve does not accept a task" do
    assert {:error, "--serve does not accept a task"} =
             Alto.CLI.run(["--no-config", "--serve", "task"])
  end

  test "serve and setup are mutually exclusive" do
    assert {:error, "choose either --serve or --setup, not both"} =
             Alto.CLI.run(["--no-config", "--serve", "--setup"])
  end

  test "serve rejects an out-of-range port", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        tools: [],
        system_prompt: nil
      )
      """
    )

    assert {:error, "invalid listener port: want 0-65535"} =
             Alto.CLI.run(["--config", path, "--serve", "--port", "99999"])
  end

  test "serve rejects unknown listener modules", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        listeners: [{String, []}]
      )
      """
    )

    assert {:error, message} = Alto.CLI.run(["--config", path, "--serve"])
    assert message =~ "invalid listeners"
  end

  test "serve rejects a non-list listeners value", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        listeners: :nope
      )
      """
    )

    assert {:error, message} = Alto.CLI.run(["--config", path, "--serve"])
    assert message =~ "invalid listeners"
  end

  test "serve rejects an invalid sessions value", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        listeners: [],
        sessions: "yes"
      )
      """
    )

    assert {:error, message} = Alto.CLI.run(["--config", path, "--serve"])
    assert message =~ "invalid sessions"
  end
end
