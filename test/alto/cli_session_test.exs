defmodule Alto.CLISessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, _opts), do: {:ok, %{message: "configured", tool_calls: []}}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-cli-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = System.get_env("ALTO_STATE_HOME")
    System.put_env("ALTO_STATE_HOME", Path.join(root, "state"))

    on_exit(fn ->
      if previous do
        System.put_env("ALTO_STATE_HOME", previous)
      else
        System.delete_env("ALTO_STATE_HOME")
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp write_config(root) do
    path = Path.join(root, "config.exs")

    File.write!(
      path,
      """
      Alto.Config.new(
        provider: Alto.CLISessionTest.AnswerProvider,
        tools: [],
        system_prompt: nil
      )
      """
    )

    path
  end

  defp session_id_from(stderr) do
    [_, id] = Regex.run(~r/alto: session (\S+)/, stderr)
    id
  end

  test "one-shot runs persist and print their session id", %{root: root} do
    path = write_config(root)

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert :ok = Alto.CLI.run(["--config", path, "answer from config"])
               end) == "configured\n"
      end)

    assert id = session_id_from(stderr)
    assert id =~ ~r/\Asess-/

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--sessions"])
           end) =~ id
  end

  test "resume continues the same session", %{root: root} do
    path = write_config(root)

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn -> Alto.CLI.run(["--config", path, "first"]) end)
      end)

    id = session_id_from(stderr)

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert :ok = Alto.CLI.run(["--config", path, "--resume", id, "follow-up"])
               end) == "configured\n"
      end)

    assert stderr =~ id
  end

  test "resume of an unknown session fails loudly", %{root: root} do
    path = write_config(root)

    assert {:error, "no such session sess-nope"} =
             Alto.CLI.run(["--config", path, "--resume", "sess-nope", "task"])
  end

  test "resume still needs a task", %{root: root} do
    path = write_config(root)

    assert capture_io("", fn ->
             assert {:error, message} = Alto.CLI.run(["--config", path, "--resume", "sess-nope"])
             assert message =~ "no task provided"
           end) == ""
  end

  test "a hostile resume id never touches the filesystem", %{root: root} do
    path = write_config(root)

    assert {:error, message} = Alto.CLI.run(["--config", path, "--resume", "../evil", "task"])
    assert message =~ "invalid session id"
  end

  test "--no-session stays silent and unpersisted", %{root: root} do
    path = write_config(root)

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 assert :ok = Alto.CLI.run(["--config", path, "--no-session", "task"])
               end) == "configured\n"
      end)

    refute stderr =~ "session"

    assert capture_io(fn ->
             assert :ok = Alto.CLI.run(["--sessions"])
           end) == "no sessions yet\n"
  end

  test "--sessions rejects a task" do
    assert {:error, "--sessions does not accept a task"} = Alto.CLI.run(["--sessions", "task"])
  end
end
