defmodule Alto.Contrib.Integration.CLIWorkflowsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Alto.Contrib.CLI

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      send(opts[:owner], {:request, request.messages})
      {:ok, %{message: "configured answer", tool_calls: []}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-cli-flow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = System.get_env("ALTO_STATE_HOME")
    System.put_env("ALTO_STATE_HOME", Path.join(root, "state"))

    on_exit(fn ->
      if previous,
        do: System.put_env("ALTO_STATE_HOME", previous),
        else: System.delete_env("ALTO_STATE_HOME")

      File.rm_rf!(root)
    end)

    config = Path.join(root, "config.exs")
    File.write!(Path.join(root, "AGENTS.md"), "Use the workspace evidence.")

    File.write!(
      config,
      "[provider: {#{inspect(Provider)}, owner: self()}, tools: [], cwd: #{inspect(root)}, project_instructions: :auto]"
    )

    %{root: root, config: config}
  end

  test "configuration and workspace instructions survive a listed and resumed CLI conversation",
       c do
    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> assert :ok = CLI.run(["--config", c.config, "first"]) end) ==
                 "configured answer\n"
      end)

    [_, id] = Regex.run(~r/alto: session (\S+)/, stderr)
    assert_receive {:request, first}

    assert Enum.any?(
             first,
             &(&1["role"] == "system" and &1["content"] =~ "Use the workspace evidence.")
           )

    assert capture_io(fn -> assert :ok = CLI.run(["--sessions"]) end) =~ id

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert :ok = CLI.run(["--config", c.config, "--resume", id, "next"])
               end) == "configured answer\n"
      end)

    assert stderr =~ id
    assert_receive {:request, resumed}
    assert List.last(resumed)["content"] == "next"
    assert Enum.count(resumed, &(&1["content"] == "first")) == 1
    assert Enum.any?(resumed, &(&1["content"] == "configured answer"))
  end

  test "unpersisted invocations stay unlisted and rejected invocations never reach the provider",
       c do
    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert :ok = CLI.run(["--config", c.config, "--no-session", "answer"])
        end)
      end)

    refute stderr =~ "session"
    assert_receive {:request, _}
    assert capture_io(fn -> assert :ok = CLI.run(["--sessions"]) end) =~ "no sessions"

    for arguments <- [
          ["--config", c.config, "--resume", "../escape", "task"],
          ["--config", c.config, "--resume", "sess-missing", "task"],
          ["--sessions", "task"],
          ["--serve", "task"],
          ["--serve", "--setup"],
          ["--config", c.config, "--no-config", "task"],
          ["--setup"]
        ] do
      assert {:error, _} = CLI.run(arguments)
      refute_received {:request, _}
    end

    for source <- [":invalid", "%{wrong: :shape}", "raise \"invalid config\"", "[max_steps: 0]"] do
      File.write!(c.config, source)

      capture_io(:stderr, fn ->
        capture_io(fn -> assert {:error, _} = CLI.run(["--config", c.config, "task"]) end)
      end)

      refute_received {:request, _}
    end
  end
end
