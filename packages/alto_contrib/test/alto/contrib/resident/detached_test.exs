defmodule Alto.Contrib.Resident.DetachedTest do
  use ExUnit.Case, async: false

  alias Alto.Contrib.Socket.Client
  alias Alto.Contrib.Resident.{Config, Service}

  defmodule ControlledProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:executing, self()})

      receive do
        :finish -> {:ok, %{message: "completed while detached", tool_calls: []}}
      end
    end
  end

  test "disconnect, finish, reconnect and replay again after service restart" do
    dir = Path.join(System.tmp_dir!(), "zek-detached-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "controlled" =>
            Alto.Config.default(
              provider: {ControlledProvider, owner: self()},
              loop: Alto.chat_loop(),
              tools: [],
              run_timeout: 10_000
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    {:ok, first} = Client.connect(Config.socket_path(config))

    {:ok, reply} =
      Client.request(first, %{"type" => "start_run", "config" => "controlled", "task" => "work"})

    run = reply["run_id"]
    session = reply["session_id"]
    assert is_binary(run) and is_binary(session)
    assert_receive {:executing, provider}, 2_000
    Client.close(first)
    assert Process.alive?(provider)
    send(provider, :finish)

    {:ok, second} = Client.connect(Config.socket_path(config))
    assert {:ok, _} = Client.request(second, %{"type" => "attach", "run_id" => run})
    result = receive_result(second)
    assert result["status"] == "ok"
    assert result["output"] == "completed while detached"

    assert {:ok, page} =
             Client.request(second, %{"type" => "session_events", "session_id" => session})

    assert page["events"] != []
    assert page["gap"] == false
    Client.close(second)

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    {:ok, third} = Client.connect(Config.socket_path(config))
    on_exit(fn -> Client.close(third) end)

    assert {:ok, replay} =
             Client.request(third, %{"type" => "session_events", "session_id" => session})

    assert replay["events"] == page["events"]
    assert {:ok, summaries} = Client.request(third, %{"type" => "sessions"})
    assert Enum.any?(summaries["sessions"], &(&1["id"] == session))
    refute_receive {:executing, _}
  end

  defp receive_result(client, remaining \\ 30)
  defp receive_result(_client, 0), do: flunk("no result from resident")

  defp receive_result(client, remaining) do
    case Client.next(client, 2_000) do
      {:ok, %{"type" => "result"} = result} -> result
      {:ok, _} -> receive_result(client, remaining - 1)
      other -> flunk("unexpected client result: #{inspect(other)}")
    end
  end
end
