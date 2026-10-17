defmodule Alto.Contrib.Socket.ClientTest do
  use ExUnit.Case, async: true

  test "correlates replies while retaining and delivering notifications" do
    {path, listener} = socket_fixture()
    hello = %{"v" => 1, "type" => "hello", "id" => "s-1", "text" => String.duplicate("猫", 5_000)}
    encoded = JSON.encode!(hello)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        <<prefix::binary-size(100), rest::binary>> = encoded
        :ok = :gen_tcp.send(socket, prefix)
        :ok = :gen_tcp.send(socket, [rest, "\r\n\n"])
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        request = JSON.decode!(String.trim(line))
        send_json(socket, %{"v" => 1, "type" => "event", "id" => "s-2", "run_id" => "run-1"})
        send_json(socket, %{"v" => 1, "type" => "ok", "id" => request["id"], "run_id" => "run-1"})

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} =
      Alto.Contrib.Socket.Client.connect(path, max_line_bytes: byte_size(encoded) + 1)

    assert {:ok, ^hello} = Alto.Contrib.Socket.Client.next(client)

    assert {:ok, %{"type" => "ok", "run_id" => "run-1"}} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"})

    assert {:ok, %{"type" => "event", "run_id" => "run-1"}} =
             Alto.Contrib.Socket.Client.next(client)

    send(server, :close)
    Alto.Contrib.Socket.Client.close(client)
    File.rm(path)
  end

  test "closes on an oversized NDJSON line" do
    for ending <- ["", "\n"] do
      {path, listener} = socket_fixture()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, String.duplicate("x", 9) <> ending)
        :gen_tcp.close(socket)
      end)

      {:ok, client} = Alto.Contrib.Socket.Client.connect(path, max_line_bytes: 8)
      assert {:error, :line_too_large} = Alto.Contrib.Socket.Client.next(client, 500)
      Alto.Contrib.Socket.Client.close(client)
      File.rm(path)
    end
  end

  test "invalid commands and expired requests release capacity without misrouting late replies" do
    {path, listener} = socket_fixture()
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        expired = JSON.decode!(String.trim(line))
        send(parent, {:request, expired})
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        current = JSON.decode!(String.trim(line))

        send_json(socket, [
          %{"v" => 1, "type" => "ok", "id" => expired["id"], "value" => "late"},
          %{"v" => 1, "type" => "ok", "id" => current["id"], "value" => "current"}
        ])

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} =
      Alto.Contrib.Socket.Client.connect(path, max_pending: 1, max_line_bytes: 100)

    for command <- [%{type: "sessions", value: {:not, :json}}, %{[] => "invalid key"}] do
      assert {:error, :invalid_command} = Alto.Contrib.Socket.Client.request(client, command)
    end

    assert {:error, :overflow} =
             Alto.Contrib.Socket.Client.request(client, %{type: String.duplicate("x", 100)})

    assert {:error, :invalid_timeout} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: -1)

    assert {:error, :invalid_timeout} = Alto.Contrib.Socket.Client.next(client, :infinity)

    assert {:error, :timeout} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: 20)

    assert_receive {:request, %{"v" => 1, "id" => "c-1", "type" => "sessions"}}

    assert {:ok, %{"id" => "c-2", "value" => "current"}} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: 1_000)

    assert {:error, :timeout} = Alto.Contrib.Socket.Client.next(client, 0)
    send(server, :close)
    Alto.Contrib.Socket.Client.close(client)
    File.rm(path)
  end

  test "an expired notification waiter leaves the remaining callers in FIFO order" do
    {path, listener} = socket_fixture()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        receive do
          :deliver ->
            send_json(socket, [
              %{"v" => 1, "type" => "event", "id" => "first"},
              %{"v" => 1, "type" => "event", "id" => "second"}
            ])
        end

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
    first = :gen_server.send_request(client.pid, {:next, 5_000})
    expired = :gen_server.send_request(client.pid, {:next, 20})
    last = :gen_server.send_request(client.pid, {:next, 5_000})
    assert {:reply, {:error, :timeout}} = :gen_server.receive_response(expired, 1_000)

    send(server, :deliver)
    assert {:reply, {:ok, %{"id" => "first"}}} = :gen_server.receive_response(first, 1_000)
    assert {:reply, {:ok, %{"id" => "second"}}} = :gen_server.receive_response(last, 1_000)
    assert {:error, :timeout} = Alto.Contrib.Socket.Client.next(client, 0)
    send(server, :close)
    Alto.Contrib.Socket.Client.close(client)
  end

  test "malformed envelopes fail closed with an explicit reason" do
    {path, listener} = socket_fixture()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.send(socket, "not-json\n")
    end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
    assert {:error, :invalid_envelope} = Alto.Contrib.Socket.Client.next(client, 500)
    assert {:error, :invalid_envelope} = Alto.Contrib.Socket.Client.next(client, 0)
  end

  for {bound, limits} <- [count: [max_events: 1], bytes: [max_event_bytes: 1]] do
    @tag limits: limits
    test "event #{bound} overflow closes the socket instead of dropping notifications", %{
      limits: limits
    } do
      {path, listener} = socket_fixture()
      parent = self()

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        events =
          for id <- 1..3,
              do: %{
                "v" => 1,
                "type" => "event",
                "id" => "e-#{id}",
                "data" => String.duplicate("x", 100)
              }

        send_json(socket, events)
        send(parent, {:overflow_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

      {:ok, client} = Alto.Contrib.Socket.Client.connect(path, limits)
      assert_receive {:overflow_closed, {:error, :closed}}, 1_500
      assert {:error, :event_buffer_overflow} = Alto.Contrib.Socket.Client.next(client)
      Alto.Contrib.Socket.Client.close(client)
    end
  end

  test "owner death closes the socket" do
    {path, _listener} = socket_fixture()
    parent = self()

    owner =
      spawn(fn ->
        {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
        send(parent, {:owner_client, self(), client})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owner_client, ^owner, client}
    Process.exit(owner, :kill)
    assert eventually_dead?(client.pid)
    Alto.Contrib.Socket.Client.close(client)
  end

  test "socket closure settles both pending requests and notification waiters" do
    {path, listener} = socket_fixture()
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :request_received)

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
    notification = :gen_server.send_request(client.pid, {:next, 5_000})
    request = :gen_server.send_request(client.pid, {:request, %{type: "sessions"}, 5_000})
    assert_receive :request_received
    send(server, :close)

    for waiter <- [notification, request] do
      assert {:reply, {:error, :closed}} = :gen_server.receive_response(waiter, 1_000)
    end
  end

  defp socket_fixture do
    path =
      Path.join(
        System.tmp_dir!(),
        "alto_resident-client-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:ip, {:local, path}}, {:active, false}, {:reuseaddr, true}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {path, listener}
  end

  defp send_json(socket, maps) when is_list(maps),
    do: :gen_tcp.send(socket, Enum.map_join(maps, "", &(JSON.encode!(&1) <> "\n")))

  defp send_json(socket, map), do: :gen_tcp.send(socket, JSON.encode!(map) <> "\n")

  defp eventually_dead?(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      1_000 -> false
    end
  end
end
