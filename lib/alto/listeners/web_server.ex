defmodule Alto.Listeners.WebServer do
  @moduledoc """
  Localhost HTTP and WebSocket front end for Alto's transport-independent
  protocol.

  Bandit owns HTTP parsing, connection lifecycle, and RFC 6455 framing. Alto
  retains only its application routes, same-origin policy, and protocol
  dispatch.
  """

  use GenServer

  alias Alto.Listeners.Connection

  @default_max_line_bytes Connection.default_max_line_bytes()

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The port the listener actually bound (useful with an ephemeral port)."
  @spec bound_port(GenServer.server()) :: :inet.port_number()
  def bound_port(server \\ __MODULE__), do: GenServer.call(server, :bound_port)

  @doc "Local WebSocket endpoint URL. Authentication is sent in the upgrade request."
  def url(server \\ __MODULE__), do: GenServer.call(server, :url)

  @doc "The generated authentication token, when token authentication is enabled."
  def token(server \\ __MODULE__), do: GenServer.call(server, :token)

  @impl true
  def init(opts) do
    case Alto.Listeners.WebAuth.normalize(Keyword.get(opts, :auth, :token)) do
      {:ok, {auth, token}} -> start_listener(opts, auth, token)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_listener(opts, auth, token) do
    registry = Keyword.fetch!(opts, :registry)
    port = Keyword.get(opts, :port, 0)
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    bandit_opts = [
      plug: {__MODULE__.Router, registry: registry, max_line_bytes: max_line_bytes, auth: auth},
      ip: {127, 0, 0, 1},
      port: port,
      startup_log: false,
      http_options: [log_protocol_errors: false, log_client_closures: false],
      websocket_options: [
        compress: false,
        max_frame_size: max_line_bytes + 14,
        max_fragmented_message_size: max_line_bytes,
        validate_text_frames: true
      ]
    ]

    case Bandit.start_link(bandit_opts) do
      {:ok, bandit} ->
        {:ok, {_address, actual_port}} = ThousandIsland.listener_info(bandit)
        {:ok, %{bandit: bandit, port: actual_port, token: token}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:bound_port, _from, state), do: {:reply, state.port, state}

  def handle_call(:url, _from, state) do
    {:reply, "ws://127.0.0.1:#{state.port}/ws", state}
  end

  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  @impl true
  def format_status(status), do: Map.update(status, :state, %{}, &Map.drop(&1, [:token]))

  @impl true
  def terminate(_reason, %{bandit: bandit}) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit)
    :ok
  end

  defmodule Router do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "GET", request_path: "/ws"} = conn, opts) do
      if allowed_origin?(conn) and
           Alto.Listeners.WebAuth.allowed?(conn, Keyword.fetch!(opts, :auth)) do
        conn =
          if conn
             |> get_req_header("sec-websocket-protocol")
             |> Enum.flat_map(&String.split(&1, ","))
             |> Enum.any?(&(String.trim(&1) == "alto.v1")),
             do: put_resp_header(conn, "sec-websocket-protocol", "alto.v1"),
             else: conn

        upgrade_adapter(
          conn,
          :websocket,
          {Alto.Listeners.WebServer.Socket, Keyword.delete(opts, :auth),
           timeout: :infinity, max_frame_size: Keyword.fetch!(opts, :max_line_bytes)}
        )
      else
        conn
        |> response_headers("text/plain; charset=utf-8")
        |> send_resp(403, "websocket access denied")
      end
    end

    def call(conn, _opts) do
      conn
      |> response_headers("text/plain; charset=utf-8")
      |> send_resp(404, "not found")
    end

    defp response_headers(conn, content_type) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
    end

    defp allowed_origin?(conn) do
      case get_req_header(conn, "origin") do
        [] ->
          true

        [origin] ->
          case URI.parse(origin) do
            %URI{scheme: "http", host: host, port: origin_port}
            when host in ["127.0.0.1", "localhost"] ->
              (origin_port || 80) == conn.port

            _other ->
              false
          end

        _multiple ->
          false
      end
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    alias Alto.FrontEnd.Registry
    alias Alto.Listeners.Connection

    @impl true
    def init(opts) do
      state = %{
        registry: Keyword.fetch!(opts, :registry),
        max_line_bytes: Keyword.fetch!(opts, :max_line_bytes)
      }

      lines = Connection.hello_lines(state.registry, state.max_line_bytes)

      Registry.pull(state.registry, self(), Connection.pull_batch())
      Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
      push(lines, state)
    end

    @impl true
    def handle_in({payload, opcode: :text}, state)
        when byte_size(payload) <= state.max_line_bytes do
      lines = Connection.command_lines(payload, state.registry, state.max_line_bytes)
      push(lines, state)
    end

    def handle_in({_payload, opcode: :text}, state),
      do: {:stop, :line_too_large, 1009, state}

    def handle_in({_payload, opcode: :binary}, state),
      do: {:stop, :binary_not_supported, 1003, state}

    @impl true
    def handle_info(:alto_wakeup, state) do
      Registry.pull(state.registry, self(), Connection.pull_batch())
      Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
      {:ok, state}
    end

    def handle_info(:alto_close, state), do: {:stop, :normal, 1000, state}

    def handle_info({:alto_notification, notification}, state) do
      lines = Connection.notification_lines(notification, state.registry, state.max_line_bytes)
      push(lines, state)
    end

    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      try do
        Registry.detach(state.registry, self())
      catch
        :exit, _reason -> :ok
      end

      :ok
    end

    defp push([], state), do: {:ok, state}
    defp push(lines, state), do: {:push, Enum.map(lines, &{:text, &1}), state}
  end
end
