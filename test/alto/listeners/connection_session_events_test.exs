defmodule Alto.Listeners.ConnectionSessionEventsTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection
  alias Alto.Session

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
