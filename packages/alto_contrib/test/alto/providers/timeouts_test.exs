defmodule Alto.Contrib.Providers.TimeoutsTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Providers.OpenAICompatible

  defp endpoint(chunks) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      spawn_link(fn ->
        case :gen_tcp.accept(listener, 5_000) do
          {:ok, socket} ->
            :gen_tcp.recv(socket, 0, 5_000)

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
            )

            Enum.each(chunks, fn {delay, data} ->
              Process.sleep(delay)

              :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
            end)

            :gen_tcp.send(socket, "0\r\n\r\n")
            :gen_tcp.close(socket)

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    "http://127.0.0.1:#{port}/chat/completions"
  end

  defp stream(endpoint, opts) do
    OpenAICompatible.stream(
      %{messages: [], tools: []},
      fn _ -> :ok end,
      Keyword.merge([model: "local-test", endpoint: endpoint], opts)
    )
  end

  test "stream progress may outlast the idle limit without exceeding total deadline" do
    chunks = for _ <- 1..6, do: {80, ": keepalive\n\n"}

    finish =
      "data: " <>
        JSON.encode!(%{
          "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]
        }) <> "\n\ndata: [DONE]\n\n"

    assert {:ok, %{message: "ok"}} =
             stream(endpoint(chunks ++ [{0, finish}]), timeout: 3_000, idle_timeout: 350)
  end

  test "a silent stream fails at its idle limit" do
    assert {:error, {:transport_error, _}} =
             stream(endpoint([{0, ": start\n\n"}, {1_000, ": late\n\n"}]),
               timeout: 3_000,
               idle_timeout: 200
             )
  end

  test "continuous heartbeats cannot evade the hard total deadline" do
    chunks = for _ <- 1..30, do: {40, ": keepalive\n\n"}

    assert {:error, {:transport_error, _}} =
             stream(endpoint(chunks), timeout: 300, idle_timeout: 1_000)
  end

  test "timeout options remain protected from provider req_options overrides" do
    config = %{
      timeout: 600,
      idle_timeout: 100,
      endpoint: "http://localhost",
      req_options: [receive_timeout: :infinity, request_timeout: :infinity]
    }

    opts = Alto.Contrib.Providers.HTTPOptions.request_options(config, [], [])
    assert opts[:receive_timeout] == 100
    assert opts[:request_timeout] == 600

    assert Alto.Contrib.Providers.HTTPOptions.request_options(
             Map.delete(config, :idle_timeout),
             [],
             []
           )[
             :receive_timeout
           ] == 600
  end
end
