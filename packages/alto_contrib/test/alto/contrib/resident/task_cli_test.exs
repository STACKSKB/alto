defmodule Alto.Contrib.Resident.TaskCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Alto.Contrib.Resident.{CLI, Config, Service}

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _opts), do: {{:stop, task}, task, []}
    def handle_event(_event, state, _opts), do: {:continue, state, []}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [poll_ms: 10, workers: 1, run_timeout: 5_000],
        profiles: %{"echo" => Alto.Config.default(provider: nil, loop: Alto.loop(Echo))}
      )

    start_supervised!({Service, config: config, name: make_ref()})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{socket: Config.socket_path(config)}
  end

  test "schedule and task inspection use the command wire", %{socket: socket} do
    assert :ok =
             CLI.run([
               "schedule",
               "echo",
               "hello",
               "--id",
               "cli-task",
               "--delay-ms",
               "60000",
               "--socket",
               socket
             ])

    listed = capture_io(fn -> assert :ok = CLI.run(["tasks", "--socket", socket]) end)
    assert listed =~ "cli-task"

    fetched = capture_io(fn -> assert :ok = CLI.run(["task", "cli-task", "--socket", socket]) end)
    assert fetched =~ "cli-task"

    assert :ok = CLI.run(["task-cancel", "cli-task", "--socket", socket])
  end

  test "reconcile requires a positive revision and explanatory note" do
    assert {:error, {:invalid_task_reconcile, :revision}} =
             CLI.run(["task-reconcile", "id", "retry", "--revision", "0", "--note", "why"])

    assert {:error, {:invalid_task_reconcile, :note}} =
             CLI.run(["task-reconcile", "id", "retry", "--revision", "1", "--note", "  "])
  end

  test "malformed scheduling options are rejected" do
    assert {:error, {:invalid_options, [{"--delay-ms", "oops"}]}} =
             CLI.run(["schedule", "echo", "hello", "--delay-ms", "oops"])
  end
end
