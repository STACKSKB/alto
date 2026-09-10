defmodule Alto.Listeners.ConnectionSessionEventsTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection
  alias Alto.Session

  test "fresh VM replays projection without creating atoms from stored terms" do
    dir = Path.join(System.tmp_dir!(), "alto-fresh-replay-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    key = "only_in_original_vm_#{System.unique_integer([:positive])}"
    data = %{String.to_atom(key) => "survives restart"}
    {:ok, id} = Session.create("task", %{}, session_dir: dir)

    :ok =
      Session.append(id, Session.event_record("run-1", Event.durable(:tool_completed, data)),
        session_dir: dir
      )

    command =
      JSON.encode!(%{"v" => 1, "id" => "replay", "type" => "session_events", "session_id" => id})

    script = """
    {:ok, page} = Alto.Session.events(#{inspect(id)}, session_dir: #{inspect(dir)})
    {:error, _} = Alto.Session.decode_term(hd(page.events)["data"])
    {:ok, registry} = Alto.FrontEnd.Registry.start_link(name: nil,
      session_dir: #{inspect(dir)}, config_resolver: fn _ -> {:error, :unknown} end)
    Alto.Listeners.Connection.run_command(#{inspect(command)}, registry, &IO.write/1)
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]

    {output, 0} =
      System.cmd(System.find_executable("elixir"), args,
        env: [{"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    reply =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "{"))
      |> JSON.decode!()

    assert reply["type"] == "ok"
    assert hd(reply["events"])["data"] == %{key => "survives restart"}
  end

  test "session event replay survives registry restart" do
    dir = Path.join(System.tmp_dir!(), "alto-conn-events-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session_id} = Session.create("task", %{}, session_dir: dir)

    :ok =
      Session.append(
        session_id,
        Session.event_record("run-1", Event.durable(:started, %{message: "working"})),
        session_dir: dir
      )

    :ok =
      Session.append(session_id, Session.event_record("run-1", Event.durable(:finished, %{})),
        session_dir: dir
      )

    name = String.to_atom("conn-events-#{System.unique_integer([:positive])}")

    start_registry = fn ->
      Registry.start_link(
        name: name,
        session_dir: dir,
        config_resolver: fn _ -> {:error, :unknown} end
      )
    end

    {:ok, pid} = start_registry.()
    assert Process.alive?(pid)
    GenServer.stop(pid)
    {:ok, restarted} = start_registry.()
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    line =
      JSON.encode!(%{
        "v" => 1,
        "type" => "session_events",
        "id" => "c-1",
        "session_id" => session_id,
        "limit" => 1
      })

    Connection.run_command(line, name, fn output -> send(self(), {:line, output}) end)
    assert_receive {:line, output}
    reply = JSON.decode!(IO.iodata_to_binary(output))
    assert reply["type"] == "ok"
    assert length(reply["events"]) == 1
    assert reply["events"] |> hd() |> Map.fetch!("ordinal") == 1
    assert hd(reply["events"])["data"] == %{"message" => "working"}
    assert reply["complete"] == false
    assert reply["high_watermark"] == 2
  end
end
