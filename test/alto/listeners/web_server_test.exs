defmodule Alto.Listeners.WebServerTest do
  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.WebServer

  @approval_timeout_ms 5_000

  defmodule EchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema do
      %{
        description: "Echo a value.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }
    end

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(%{"value" => value}, _context), do: {:ok, %{echo: value}}
  end

  defmodule GuardedEchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema, do: EchoTool.schema()

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :required

    @impl true
    def run(arguments, _context), do: EchoTool.run(arguments, nil)
  end

  defmodule ToolThenAnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, sink, _opts) do
      sink.(Alto.Event.live(:model_delta, %{text: "partial"}))

      if Enum.any?(request.messages, &(&1["role"] == "tool")) do
        {:ok, %{message: "finished", tool_calls: []}}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [%{id: "call-1", name: "echo", arguments_json: ~s({"value":"hello"})}]
         }}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-web-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    registry = :"registry-#{System.unique_integer([:positive])}"
    listener = :"web-#{System.unique_integer([:positive])}"

    resolver = fn
      "tool-loop" ->
        {:ok, [provider: ToolThenAnswerProvider, tools: [EchoTool]]}

      "guarded-loop" ->
        {:ok,
         [
           provider: ToolThenAnswerProvider,
           tools: [GuardedEchoTool],
           approval: Alto.Approvals.Socket,
           approval_timeout: @approval_timeout_ms
         ]}

      other ->
        {:error, {:unknown_config, other}}
    end

    start_supervised!({Registry, name: registry, config_resolver: resolver, cwd: root})
    start_supervised!({WebServer, registry: registry, port: 0, name: listener})
    port = WebServer.bound_port(listener)

    %{registry: registry, listener: listener, port: port}
  end

  test "serves the GUI page on GET /", %{port: port} do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)

    assert response =~ "200 OK"
    assert response =~ "text/html; charset=utf-8"
    assert response =~ "<title>Alto</title>"
  end

  test "rejects websocket upgrades from foreign origins", %{port: port} do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    :ok =
      :gen_tcp.send(
        socket,
        "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" <>
          "Origin: http://evil.example:80\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "403"
  end

  test "speaks the protocol over websocket frames", %{port: port} do
    {socket, buffer} = ws_connect(port, "http://127.0.0.1:#{port}")

    {hello, buffer} = recv_envelope(socket, buffer)
    assert hello["type"] == "hello"

    # Attach before starting: live events only reach current subscribers,
    # so subscribing first keeps the model_delta assertion deterministic.
    send_envelope(socket, %{"type" => "attach", "id" => "c-1"})
    {_ok, buffer} = recv_until(socket, buffer, &(&1["type"] == "ok" and &1["id"] == "c-1"))

    send_envelope(socket, %{
      "type" => "start_run",
      "id" => "c-2",
      "config" => "tool-loop",
      "task" => "t"
    })

    {ok, buffer} = recv_until(socket, buffer, &(&1["type"] == "ok" and &1["id"] == "c-2"))
    assert %{"run_id" => run_id} = ok

    {envelopes, _buffer} = recv_until_result(socket, buffer, run_id)

    assert %{
             "type" => "result",
             "run_id" => ^run_id,
             "outcome" => "ok",
             "output" => "finished",
             "model_requests" => 2
           } = List.last(envelopes)

    assert Enum.any?(envelopes, &(&1["type"] == "event" and &1["event"]["type"] == "model_delta"))
  end

  test "approval decisions round-trip over the websocket", %{port: port} do
    {socket, buffer} = ws_connect(port, "http://localhost:#{port}")

    {_hello, buffer} = recv_envelope(socket, buffer)

    # Attach before starting: the approval request is live-only, so a
    # subscriber that arrives after it is published would miss it.
    send_envelope(socket, %{"type" => "attach", "id" => "c-1"})
    {_ok, buffer} = recv_until(socket, buffer, &(&1["type"] == "ok" and &1["id"] == "c-1"))

    send_envelope(socket, %{
      "type" => "start_run",
      "id" => "c-2",
      "config" => "guarded-loop",
      "task" => "t"
    })

    {ok, buffer} = recv_until(socket, buffer, &(&1["type"] == "ok" and &1["id"] == "c-2"))
    assert %{"run_id" => run_id} = ok

    {request, buffer} = recv_until(socket, buffer, &(&1["type"] == "approval_request"))
    assert request["request"]["call_id"] == "call-1"
    assert request["request"]["run_id"] == run_id
    approval_id = request["request"]["id"]
    assert approval_id == request["request"]["operation_id"]

    send_envelope(socket, %{
      "type" => "approval_response",
      "id" => "c-3",
      "request_id" => approval_id,
      "decision" => "approve"
    })

    {resolved, buffer} = recv_until(socket, buffer, &(&1["type"] == "approval_resolved"))
    assert resolved["decision"] == "approved"
    assert resolved["run_id"] == run_id

    {result, _buffer} = recv_until(socket, buffer, &(&1["type"] == "result"))
    assert result["run_id"] == run_id
    assert result["outcome"] == "ok"
  end

  test "replies with unknown_run errors over the websocket", %{port: port} do
    {socket, buffer} = ws_connect(port, "http://127.0.0.1:#{port}")
    {_hello, buffer} = recv_envelope(socket, buffer)

    send_envelope(socket, %{"type" => "cancel", "id" => "c-9", "run_id" => "run-999"})
    {error, _buffer} = recv_envelope(socket, buffer)
    assert %{"type" => "error", "id" => "c-9", "code" => "unknown_run"} = error
  end

  ## WebSocket test helpers

  defp ws_connect(port, origin) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET /ws HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: " <>
        key <>
        "\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        if(origin, do: "Origin: " <> origin <> "\r\n", else: "") <>
        "\r\n"

    :ok = :gen_tcp.send(socket, request)
    {head, rest} = recv_head(socket, "")
    assert head =~ "101 Switching Protocols"

    assert String.downcase(head) =~
             "sec-websocket-accept: " <> String.downcase(expected_accept(key))

    {socket, rest}
  end

  defp expected_accept(key) do
    :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
  end

  defp recv_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_only] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        recv_head(socket, acc <> data)
    end
  end

  defp send_envelope(socket, envelope) do
    :gen_tcp.send(socket, client_text_frame(JSON.encode!(Map.put_new(envelope, "v", 1))))
  end

  defp client_text_frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    masked = xor_mask(payload, mask)
    len = byte_size(payload)

    head =
      if len < 126 do
        <<0x81, 0x80 + len>>
      else
        <<0x81, 0x80 + 126, len::size(16)>>
      end

    [head, mask, masked]
  end

  defp xor_mask(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp recv_envelope(socket, buffer) do
    {opcode, payload, buffer} = recv_frame(socket, buffer)
    assert opcode == 0x1
    {JSON.decode!(payload), buffer}
  end

  defp recv_frame(socket, buffer) when byte_size(buffer) < 2 do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    recv_frame(socket, buffer <> data)
  end

  defp recv_frame(
         socket,
         <<_fin::1, _rsv::3, opcode::4, 0::1, len::7, rest::binary>> = buffer
       ) do
    case len do
      126 ->
        if byte_size(rest) < 2 do
          {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
          recv_frame(socket, buffer <> data)
        else
          <<extended::16, remaining::binary>> = rest
          recv_payload(socket, buffer, opcode, extended, remaining)
        end

      127 ->
        if byte_size(rest) < 8 do
          {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
          recv_frame(socket, buffer <> data)
        else
          <<extended::64, remaining::binary>> = rest
          recv_payload(socket, buffer, opcode, extended, remaining)
        end

      len ->
        recv_payload(socket, buffer, opcode, len, rest)
    end
  end

  # A frame split across TCP segments must wait for more bytes; recursing
  # on the same buffer without reading would spin forever.
  defp recv_payload(socket, buffer, opcode, payload_len, rest) do
    if byte_size(rest) < payload_len do
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      recv_frame(socket, buffer <> data)
    else
      <<payload::size(payload_len)-binary, remaining::binary>> = rest
      {opcode, payload, remaining}
    end
  end

  defp recv_until(socket, buffer, pred) do
    {envelope, buffer} = recv_envelope(socket, buffer)

    if pred.(envelope) do
      {envelope, buffer}
    else
      recv_until(socket, buffer, pred)
    end
  end

  defp recv_until_result(socket, buffer, run_id) do
    {envelope, buffer} = recv_envelope(socket, buffer)

    case envelope do
      %{"type" => "result", "run_id" => ^run_id} ->
        {[envelope], buffer}

      other ->
        {rest, buffer} = recv_until_result(socket, buffer, run_id)
        {[other | rest], buffer}
    end
  end
end
