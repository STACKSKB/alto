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
    assert {:error, {:invalid_argument, :revision}} =
             CLI.run(~w(task-reconcile id retry --revision 0 --note why))

    assert {:error, {:invalid_argument, :note}} =
             CLI.run(["task-reconcile", "id", "retry", "--revision", "1", "--note", "  "])
  end

  test "commands and watches send their fields and close after success or rejection", %{
    socket: service_socket
  } do
    socket = Path.join(Path.dirname(service_socket), "cli-probe.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {:local, socket}])

    on_exit(fn -> :gen_tcp.close(listener) end)

    for {args, expected, rejected?} <- [
          {~w(team-result batch child --generation gen --revision 2),
           %{
             "type" => "command",
             "name" => "children.result",
             "payload" => %{
               "key" => "batch",
               "child" => "child",
               "generation" => "gen",
               "revision" => 2,
               "cursor" => 0
             }
           }, false},
          {~w(task-reconcile task retry --revision 3 --note checked),
           %{
             "type" => "command",
             "name" => "tasks.reconcile",
             "payload" => %{
               "id" => "task",
               "resolution" => "retry",
               "revision" => 3,
               "note" => "checked"
             }
           }, true},
          {~w(watch run --from-seq 7), %{"type" => "attach", "run_id" => "run", "from_seq" => 7},
           false},
          {~w(watch run), %{"type" => "attach", "run_id" => "run", "from_seq" => 1}, true}
        ] do
      server =
        Task.async(fn ->
          {:ok, connection} = :gen_tcp.accept(listener, 5_000)
          {:ok, line} = :gen_tcp.recv(connection, 0, 5_000)
          request = JSON.decode!(line)

          type = if rejected?, do: "error", else: "ok"
          payload = if rejected?, do: %{code: "stale", detail: "changed"}, else: %{}
          {:ok, reply} = Alto.Contrib.Protocol.envelope(type, request["id"], payload, 1024)
          :ok = :gen_tcp.send(connection, reply)

          if expected["type"] == "attach" and not rejected? do
            :ok =
              :gen_tcp.send(
                connection,
                ~s({"v":1,"id":"event","type":"result","output":"finished"}\n)
              )
          end

          assert {:error, :closed} = :gen_tcp.recv(connection, 0, 5_000)
          :gen_tcp.close(connection)
          Map.drop(request, ~w(v id))
        end)

      output =
        capture_io(fn ->
          if rejected?,
            do:
              assert(
                {:error, {:server, "stale", "changed"}} = CLI.run(args ++ ["--socket", socket])
              ),
            else: assert(:ok = CLI.run(args ++ ["--socket", socket]))
        end)

      assert Task.await(server, 15_000) == expected

      if expected["type"] == "attach" and not rejected?,
        do: assert(JSON.decode!(output)["output"] == "finished")

      if rejected?, do: assert(output == "")
    end
  end

  test "invalid choices, cursors, identifiers and arities fail before connecting" do
    for {args, field} <- [
          {~w(task-decide id maybe --revision 1), :decision},
          {~w(task-child-decide id child maybe), :decision},
          {~w(task-reconcile id maybe), :resolution},
          {~w(workspaces --cursor -1), :cursor},
          {~w(history session --cursor -1), :cursor},
          {~w(watch run --from-seq 0), :from_seq},
          {["watch", ""], :run_id},
          {["task", "  "], :id},
          {["task-recover", "id", ""], :key},
          {~w(team-result key child), :generation},
          {["team-result", "key", "child", "--generation", "", "--revision", "1"], :generation},
          {~w(team-result key child --generation gen --revision 1 --cursor -1), :cursor},
          {~w(task-recover id key), :revision},
          {~w(task-recover id key --revision 0 --generation gen --continuation-revision 1),
           :revision},
          {~w(task-recover id key --revision 1 --continuation-revision 1 --generation) ++ [""],
           :generation},
          {~w(task-recover id key --revision 1 --generation gen --continuation-revision 0),
           :continuation_revision}
        ] do
      assert {:error, {:invalid_argument, ^field}} = CLI.run(args)
    end

    for args <- [~w(task), ~w(tasks extra), ~w(team-result key), ~w(unknown)],
        do: assert({:error, :invalid_command} = CLI.run(args))
  end

  test "malformed scheduling options are rejected" do
    assert {:error, {:invalid_options, [{"--delay-ms", "oops"}]}} =
             CLI.run(~w(schedule echo hello --delay-ms oops))
  end
end
