defmodule Alto.Listeners.UnixSocketTest do
  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.UnixSocket

  # Generous for parallel-test load; the fail-closed timeout path is pinned
  # by the registry tests with a tight, controlled bound.
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

  # The request's own messages tell the provider which phase of the loop it
  # is in; no per-run test pid is needed over the wire.
  defmodule ToolThenAnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, _opts) do
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

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, _opts) do
      receive(do: (:never -> {:ok, %{message: nil, tool_calls: []}}))
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-listener-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    registry = :"registry-#{System.unique_integer([:positive])}"
    path = Path.join([root, "run", "alto.sock"])

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

      "blocking-loop" ->
        {:ok, [provider: BlockingProvider, tools: [], max_steps: 1]}

      other ->
        {:error, {:unknown_config, other}}
    end

    start_supervised!({Registry, name: registry, config_resolver: resolver, cwd: root})
    start_supervised!({UnixSocket, registry: registry, path: path, name: UnixSocket})

    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}])

    %{root: root, path: path, registry: registry, socket: socket, buffer: ""}
  end

  test "supervised shutdown removes the socket and stops its acceptor", %{path: path} do
    acceptor = :sys.get_state(UnixSocket).acceptor
    monitor = Process.monitor(acceptor)

    assert :ok = stop_supervised(UnixSocket)
    refute File.exists?(path)
    assert_receive {:DOWN, ^monitor, :process, ^acceptor, _reason}
    assert {:error, :enoent} = :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}])
  end

  test "acceptor failure terminates the listener instead of leaving an inert socket", %{
    root: root,
    registry: registry
  } do
    path = Path.join(root, "acceptor-failure.sock")
    name = :"acceptor-listener-#{System.unique_integer([:positive])}"
    spec = listener_spec(name, registry, path, name) |> Map.put(:restart, :temporary)
    listener = start_supervised!(spec)
    monitor = Process.monitor(listener)
    acceptor = :sys.get_state(listener).acceptor

    Process.exit(acceptor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^listener, {:acceptor_stopped, :killed}}
    refute File.exists?(path)
  end

  test "greets with the protocol version, live runs, and the line bound", %{
    socket: socket,
    path: path,
    buffer: buffer
  } do
    {hello, _buffer} = recv_json(socket, buffer)

    assert hello["v"] == 1
    assert hello["type"] == "hello"
    assert hello["runs"] == []
    assert hello["max_line_bytes"] == 1_048_576

    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "starts a run, streams events, and finishes with one result", %{
    socket: socket,
    buffer: buffer
  } do
    {_hello, buffer} = recv_json(socket, buffer)

    send_command(socket, %{
      "v" => 1,
      "type" => "start_run",
      "id" => "c-1",
      "config" => "tool-loop",
      "task" => "use the tool"
    })

    {ok, buffer} = recv_ok(socket, buffer, "c-1")
    assert %{"run_id" => run_id} = ok

    send_command(socket, %{"v" => 1, "type" => "attach", "id" => "c-2", "run_id" => run_id})
    {_ok, buffer} = recv_ok(socket, buffer, "c-2")

    {envelopes, _buffer} = recv_until_result(socket, buffer, run_id)

    # The attach races the run: durable events emitted before it arrives
    # come back inside the attached replay, later ones as live envelopes.
    # The union is gapless; neither side alone is.
    durable =
      envelopes
      |> Enum.flat_map(fn
        %{"type" => "event", "seq" => seq} when is_integer(seq) -> [seq]
        %{"type" => "attached", "events" => replay} -> Enum.map(replay, & &1["seq"])
        _other -> []
      end)
      |> Enum.sort()

    assert durable == [1, 2, 3, 4, 5]

    assert %{
             "v" => 1,
             "type" => "result",
             "run_id" => ^run_id,
             "outcome" => "ok",
             "output" => "finished",
             "model_requests" => 2
           } = List.last(envelopes)
  end

  test "approval requests round-trip through the socket", %{socket: socket, buffer: buffer} do
    {_hello, buffer} = recv_json(socket, buffer)

    # Attach before starting: the approval request is live-only, so a
    # subscriber that arrives after it is published would miss it.
    send_command(socket, %{"v" => 1, "type" => "attach", "id" => "c-1"})
    {_ok, buffer} = recv_ok(socket, buffer, "c-1")

    send_command(socket, %{
      "v" => 1,
      "type" => "start_run",
      "id" => "c-2",
      "config" => "guarded-loop",
      "task" => "t"
    })

    {ok, buffer} = recv_ok(socket, buffer, "c-2")
    assert %{"run_id" => run_id} = ok

    {request_envelope, buffer} = recv_until(socket, buffer, &(&1["type"] == "approval_request"))

    assert request_envelope["run_id"] == run_id
    assert request_envelope["request"]["call_id"] == "call-1"
    assert request_envelope["request"]["run_id"] == run_id
    assert request_envelope["request"]["operation_id"] == request_envelope["request"]["id"]

    assert request_envelope["request"]["tool"] == "echo"

    approval_id = request_envelope["request"]["id"]

    send_command(socket, %{
      "v" => 1,
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

  test "cancels a run and observes the cancelled outcome", %{socket: socket, buffer: buffer} do
    {_hello, buffer} = recv_json(socket, buffer)

    send_command(socket, %{
      "v" => 1,
      "type" => "start_run",
      "id" => "c-1",
      "config" => "blocking-loop",
      "task" => "t"
    })

    {ok, buffer} = recv_ok(socket, buffer, "c-1")
    assert %{"run_id" => run_id} = ok

    send_command(socket, %{"v" => 1, "type" => "attach", "id" => "c-2", "run_id" => run_id})
    {_ok, buffer} = recv_ok(socket, buffer, "c-2")
    {_attached, buffer} = recv_until(socket, buffer, &(&1["type"] == "attached"))

    send_command(socket, %{
      "v" => 1,
      "type" => "cancel",
      "id" => "c-3",
      "run_id" => run_id,
      "reason" => "operator_stop"
    })

    {_cancel_ok, buffer} = recv_ok(socket, buffer, "c-3")

    {result, _buffer} = recv_until(socket, buffer, &(&1["type"] == "result"))
    assert result["outcome"] == "cancelled"
    assert result["reason"] == "operator_stop"
  end

  test "replies with error codes for unknown types, malformed lines, and unknown runs", %{
    socket: socket,
    buffer: buffer
  } do
    {_hello, buffer} = recv_json(socket, buffer)

    :gen_tcp.send(socket, JSON.encode!(%{"v" => 1, "type" => "ping", "id" => "c-9"}) <> "\n")
    {error, buffer} = recv_json(socket, buffer)

    assert %{"type" => "error", "id" => "c-9", "code" => "unknown_type"} = error

    :gen_tcp.send(socket, "this is not json\n")
    {error, buffer} = recv_json(socket, buffer)
    assert error["code"] == "invalid"

    send_command(socket, %{"v" => 1, "type" => "cancel", "id" => "c-10", "run_id" => "run-999"})
    {error, _buffer} = recv_json(socket, buffer)
    assert error["code"] == "unknown_run"
  end

  test "closes the connection for a line over the announced bound", %{
    socket: socket,
    buffer: buffer
  } do
    {_hello, _buffer} = recv_json(socket, buffer)

    :gen_tcp.send(socket, String.duplicate("x", 1_048_577) <> "\n")

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "ignores empty lines instead of answering with an error", %{
    socket: socket,
    buffer: buffer
  } do
    {_hello, _buffer} = recv_json(socket, buffer)

    :gen_tcp.send(socket, "\n")

    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 500)
  end

  test "replaces a stale socket left by an unclean shutdown", %{
    root: root,
    registry: registry,
    buffer: _buffer
  } do
    path = Path.join([root, "stale", "alto.sock"])
    File.mkdir_p!(Path.dirname(path))

    {:ok, occupant} = :gen_tcp.listen(0, [:binary, {:ip, {:local, path}}])
    # Unclean shutdown: the listening socket closes without unlinking.
    :gen_tcp.close(occupant)

    name = :"stale-listener-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             start_supervised(listener_spec(name, registry, path, name))

    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}])
    {hello, _buffer} = recv_json(socket, "")
    assert hello["type"] == "hello"
  end

  test "refuses to steal a live socket", %{root: root, registry: registry} do
    path = Path.join([root, "live", "alto.sock"])
    File.mkdir_p!(Path.dirname(path))

    {:ok, occupant} = :gen_tcp.listen(0, [:binary, {:ip, {:local, path}}])
    on_exit(fn -> :gen_tcp.close(occupant) end)

    name = :"live-listener-#{System.unique_integer([:positive])}"

    assert {:error, {{:socket_bind_failed, _path, :already_in_use}, _}} =
             start_supervised(listener_spec(name, registry, path, name))
  end

  test "refuses a pre-existing non-socket file", %{root: root, registry: registry} do
    path = Path.join([root, "taken", "alto.sock"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not a socket")

    name = :"taken-listener-#{System.unique_integer([:positive])}"

    assert {:error, {{:socket_bind_failed, _path, :path_taken}, _}} =
             start_supervised(listener_spec(name, registry, path, name))
  end

  # The suite setup already supervises one UnixSocket child (id
  # `Alto.Listeners.UnixSocket`), so extra listeners use explicit child ids.
  defp listener_spec(id, registry, path, name) do
    %{
      id: id,
      start: {UnixSocket, :start_link, [[registry: registry, path: path, name: name]]}
    }
  end

  defp send_command(socket, envelope) do
    :gen_tcp.send(socket, JSON.encode!(envelope) <> "\n")
  end

  defp recv_json(socket, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] -> {JSON.decode!(line), rest}
      [_incomplete] -> recv_more(socket, buffer)
    end
  end

  defp recv_more(socket, buffer) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    recv_json(socket, buffer <> data)
  end

  defp recv_ok(socket, buffer, id) do
    {envelope, buffer} = recv_until(socket, buffer, &(&1["type"] == "ok" and &1["id"] == id))
    {envelope, buffer}
  end

  defp recv_until(socket, buffer, pred) do
    {envelope, buffer} = recv_json(socket, buffer)

    if pred.(envelope) do
      {envelope, buffer}
    else
      recv_until(socket, buffer, pred)
    end
  end

  defp recv_until_result(socket, buffer, run_id) do
    {envelope, buffer} = recv_json(socket, buffer)

    case envelope do
      %{"type" => "result", "run_id" => ^run_id} ->
        {[envelope], buffer}

      other ->
        {rest, buffer} = recv_until_result(socket, buffer, run_id)
        {[other | rest], buffer}
    end
  end
end
