defmodule Alto.Contrib.Socket.ClientTest do
  use ExUnit.Case, async: true

  test "correlates replies while retaining and delivering notifications" do
    {path, listener} = socket_fixture()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send_json(socket, %{"v" => 1, "type" => "hello", "id" => "s-1"})
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        request = JSON.decode!(String.trim(line))
        send_json(socket, %{"v" => 1, "type" => "event", "id" => "s-2", "run_id" => "run-1"})
        send_json(socket, %{"v" => 1, "type" => "ok", "id" => request["id"], "run_id" => "run-1"})

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
    assert {:ok, %{"type" => "hello"}} = Alto.Contrib.Socket.Client.next(client)

    assert {:ok, %{"type" => "ok", "run_id" => "run-1"}} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"})

    assert {:ok, %{"type" => "event", "run_id" => "run-1"}} =
             Alto.Contrib.Socket.Client.next(client)

    send(server, :close)
    Alto.Contrib.Socket.Client.close(client)
    File.rm(path)
  end

  test "closes on an oversized NDJSON line" do
    {path, listener} = socket_fixture()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.send(socket, String.duplicate("x", 20) <> "\n")
      :gen_tcp.close(socket)
    end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path, max_line_bytes: 8)
    assert {:error, :line_too_large} = Alto.Contrib.Socket.Client.next(client, 500)
    Alto.Contrib.Socket.Client.close(client)
    File.rm(path)
  end

  test "request timeout is cleaned up" do
    {path, listener} = socket_fixture()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _line} = :gen_tcp.recv(socket, 0, 1_000)

      receive do
        :close -> :gen_tcp.close(socket)
      end
    end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path, max_pending: 1)

    assert {:error, :invalid_timeout} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: -1)

    assert {:error, :invalid_timeout} = Alto.Contrib.Socket.Client.next(client, :infinity)

    assert {:error, :timeout} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: 20)

    assert {:error, :timeout} =
             Alto.Contrib.Socket.Client.request(client, %{"type" => "sessions"}, timeout: 20)

    Alto.Contrib.Socket.Client.close(client)
    File.rm(path)
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

  test "event count overflow is explicit rather than silently dropping" do
    {path, listener} = socket_fixture()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)

      send_json(socket, [
        %{"v" => 1, "type" => "event", "id" => "e-1"},
        %{"v" => 1, "type" => "event", "id" => "e-2"},
        %{"v" => 1, "type" => "event", "id" => "e-3"}
      ])

      receive do
        :close -> :gen_tcp.close(socket)
      end
    end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path, max_events: 1)
    assert eventually_overflow(client)
    Alto.Contrib.Socket.Client.close(client)
  end

  test "event byte overflow is explicit" do
    {path, listener} = socket_fixture()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)

      send_json(socket, [
        %{"v" => 1, "type" => "event", "id" => "e-1", "data" => String.duplicate("x", 100)},
        %{"v" => 1, "type" => "event", "id" => "e-2", "data" => String.duplicate("x", 100)}
      ])

      receive do
        :close -> :gen_tcp.close(socket)
      end
    end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path, max_event_bytes: 1)
    assert eventually_overflow(client)
    Alto.Contrib.Socket.Client.close(client)
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

  test "a waiting next receives the socket close reason" do
    {path, listener} = socket_fixture()
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(parent, :accepted)

        receive do
          :close -> :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = Alto.Contrib.Socket.Client.connect(path)
    assert_receive :accepted
    task = Task.async(fn -> Alto.Contrib.Socket.Client.next(client, 5_000) end)
    send(server, :close)
    assert {:error, :closed} = Task.await(task, 1_000)
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

  defp eventually_overflow(client, attempts \\ 3)
  defp eventually_overflow(_client, 0), do: false

  defp eventually_overflow(client, attempts) do
    case Alto.Contrib.Socket.Client.next(client, 500) do
      {:error, :event_buffer_overflow} -> true
      {:ok, _event} -> eventually_overflow(client, attempts - 1)
      {:error, :closed} -> false
      {:error, _reason} -> eventually_overflow(client, attempts - 1)
    end
  end
end
