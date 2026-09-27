defmodule Alto.CLITest do
  use ExUnit.Case, async: false

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
    use Alto.Tool, name: :providerless_echo, execution_mode: :parallel, approval: :never

    @impl true
    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def run(arguments, _context, _opts), do: {:ok, arguments}
  end

  defmodule CustomListener do
    def start_link(_opts), do: {:error, :custom_listener_reached}
  end

  defmodule CaptureListener do
    def start_link(opts) do
      send(Alto.CLITest, {:registry, Keyword.fetch!(opts, :registry)})
      {:ok, self()}
    end
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

  test "runs with the configured provider", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.AnswerProvider,
        tools: [],
        prompt: nil
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

  test "an explicitly empty tool list disables default tools", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.NoToolsProvider,
        tools: [],
        prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "ignore tools"])
           end) == "tool-free\n"
  end

  test "default CLI tools include bounded repository search", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLITest.DefaultToolsProvider,
        prompt: nil
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
        prompt: nil
      )
      """
    )

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--config", path, "stream once"])
           end) == "streamed\n"
  end

  test "a configured provider keeps its model", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: {Alto.CLITest.ModelReportingProvider, model: "configured-model"},
        tools: [],
        prompt: nil
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
        prompt: nil
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

  test "an omitted provider keeps the default onboarding path", %{root: root} do
    names = [
      "ALTO_API_KEY",
      "OPENROUTER_API_KEY",
      "OPENAI_API_KEY",
      "ALTO_MODEL"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    previous_state_home = System.get_env("ALTO_STATE_HOME")
    previous_config_home = System.get_env("XDG_CONFIG_HOME")
    System.put_env("ALTO_STATE_HOME", root)
    System.put_env("XDG_CONFIG_HOME", root)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if previous_state_home,
        do: System.put_env("ALTO_STATE_HOME", previous_state_home),
        else: System.delete_env("ALTO_STATE_HOME")

      if previous_config_home,
        do: System.put_env("XDG_CONFIG_HOME", previous_config_home),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert {:error, message} = Alto.CLI.run(["--no-config", "model task"])

    assert message =~ "OpenRouter API key required"
  end

  for approval <- [nil, :approve] do
    @approval approval
    test "providerless served writes use #{approval || "socket approval by default"}", %{
      root: root
    } do
      Process.register(self(), __MODULE__)
      path = Path.join(root, "server.exs")
      approval_option = if @approval, do: "approval: #{inspect(@approval)},", else: ""

      File.write!(path, """
      Alto.Config.new(
        #{approval_option}
        provider: nil,
        cwd: #{inspect(root)},
        tools: [Alto.Tools.WriteFile],
        listeners: [{Alto.CLITest.CaptureListener, []}],
        runs: %{"rule" => [loop: Alto.rule_loop(steps: ["write_file"])]}
      )
      """)

      {server, monitor} = spawn_monitor(fn -> Alto.CLI.run(["--config", path, "--serve"]) end)

      try do
        assert_receive {:registry, registry}, 2_000
        registry_monitor = Process.monitor(registry)
        :ok = Alto.FrontEnd.Registry.request(registry, {:attach, self(), nil, 1, []})
        client = self()

        puller =
          Task.async(fn ->
            Stream.repeatedly(fn ->
              Alto.FrontEnd.Registry.pull(registry, client, 100)
              Process.sleep(10)
            end)
            |> Stream.run()
          end)

        try do
          task = JSON.encode!(%{path: "approved.txt", content: "configured write"})

          assert {:ok, id} =
                   Alto.FrontEnd.Registry.request(registry, {:start_run, "rule", task, []})

          unless @approval do
            assert_receive {:alto_notification, {:approval_request, ^id, request}}, 2_000
            refute File.exists?(Path.join(root, "approved.txt"))

            :ok =
              Alto.FrontEnd.Registry.request(registry, {:approval_response, request.id, :approve})
          end

          assert_receive {:alto_notification, {:result, ^id, %{status: :ok}}}, 2_000
          assert File.read!(Path.join(root, "approved.txt")) == "configured write"
          assert Process.alive?(server)
        after
          Task.shutdown(puller, :brutal_kill)
          Process.exit(server, :kill)
        end

        assert_receive {:DOWN, ^registry_monitor, :process, ^registry, _reason}, 2_000
      after
        Process.exit(server, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000
      end
    end
  end

  test "one-shot config controls workspace, write authority and persistence", %{root: root} do
    path = Path.join(root, "write.exs")

    File.write!(path, """
    Alto.Config.new(
      provider: nil,
      cwd: #{inspect(root)},
      session: nil,
      loop: Alto.rule_loop(steps: ["write_file"]),
      tools: [Alto.Tools.WriteFile],
      approval: :approve
    )
    """)

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert :ok =
                          Alto.CLI.run([
                            "--config",
                            path,
                            ~s({"path":"created.txt","content":"hello"})
                          ])
               end) == "\n"
      end)

    refute stderr =~ "session"
    assert File.read!(Path.join(root, "created.txt")) == "hello"
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
        prompt: nil
      )
      """
    )

    assert {:error, "invalid listener port: want 0-65535"} =
             Alto.CLI.run(["--config", path, "--serve", "--port", "99999"])
  end

  test "serve accepts a composed listener module", %{root: root} do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      "Alto.Config.new(provider: Alto.CLITest.AnswerProvider, listeners: [{Alto.CLITest.CustomListener, []}])"
    )

    assert {:error, "Custom listener reached"} =
             Alto.CLI.run(["--config", path, "--serve"])
  end
end
