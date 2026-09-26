defmodule Alto.Listeners.ConnectionMessagingTest do
  use ExUnit.Case, async: true
  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _, opts) do
      send(opts[:owner], {:request, request, self()})
      receive do: (:answer -> {:ok, %{message: "done", tool_calls: []}})
    end
  end

  defp command(registry, type, fields) do
    envelope = Map.merge(%{"v" => 1, "type" => type, "id" => "test"}, fields)
    [line] = Connection.command_lines(JSON.encode!(envelope), registry)
    line |> IO.iodata_to_binary() |> JSON.decode!()
  end

  test "wire commands steer the root, route to an agent, and expose consumed IDs" do
    owner = self()

    registry =
      start_supervised!(
        {Registry,
         name: nil, config_resolver: fn _ -> {:ok, [provider: {Provider, owner: owner}]} end}
      )

    started = command(registry, "start_run", %{"config" => "test", "task" => "root"})
    id = started["run_id"]
    assert_receive {:request, _, worker}, 5_000
    listed = command(registry, "list_agents", %{"run_id" => id})
    [%{"agent_id" => agent}] = listed["agents"]

    fields = %{
      "run_id" => id,
      "to" => agent,
      "text" => "new direction",
      "idempotency_key" => "submission-1"
    }

    queued = command(registry, "send_message", fields)
    assert queued["status"] == "queued"
    duplicate = command(registry, "send_message", fields)
    assert duplicate["message_id"] == queued["message_id"]
    send(worker, :answer)
    assert_receive {:request, request, worker}, 5_000
    assert List.last(request.messages)["content"] == "new direction"
    consumed = command(registry, "send_message", fields)
    assert consumed["status"] == "consumed"

    follow_up =
      command(registry, "send_message", %{
        "run_id" => id,
        "text" => "follow up",
        "delivery" => "follow_up"
      })

    assert follow_up["status"] == "queued"
    send(worker, :answer)
    assert_receive {:request, request, worker}, 5_000
    assert List.last(request.messages)["content"] == "follow up"
    send(worker, :answer)
    eventually(fn -> assert {:ok, _} = Registry.run_result(registry, id) end)
    assert command(registry, "send_message", fields)["status"] == "consumed"
    assert {:error, :recipient_closed} = Registry.send_message(registry, id, text: "late")
    assert {:ok, []} = Registry.input_status(registry, id)
    {:ok, result} = Registry.run_result(registry, id)
    assert {:ok, result} = result

    assert Enum.any?(result.events, fn event ->
             event.type == :input_received and event.data.message_id == queued["message_id"]
           end)

    assert command(registry, "send_message", %{
             "run_id" => id,
             "text" => "x",
             "delivery" => "interrupt"
           })["code"] == "invalid"
  end

  defp eventually(fun, attempts \\ 100) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(5)
      eventually(fun, attempts - 1)
  end
end
