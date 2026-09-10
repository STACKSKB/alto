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

  @impl true
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    port = Keyword.get(opts, :port, 0)
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    bandit_opts = [
      plug: {__MODULE__.Router, registry: registry, max_line_bytes: max_line_bytes},
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
        {:ok, %{bandit: bandit, port: actual_port}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:bound_port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, %{bandit: bandit}) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit)
    :ok
  end

  defmodule Router do
    @moduledoc false

    import Plug.Conn

    alias Alto.FrontEnd.Gui

    def init(opts), do: opts

    def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
      conn
      |> response_headers("text/html; charset=utf-8")
      |> send_resp(200, Gui.html())
    end

    def call(%Plug.Conn{method: "GET", request_path: "/ws"} = conn, opts) do
      if allowed_origin?(conn) do
        upgrade_adapter(
          conn,
          :websocket,
          {Alto.Listeners.WebServer.Socket, opts,
           timeout: :infinity, max_frame_size: Keyword.fetch!(opts, :max_line_bytes)}
        )
      else
        conn
        |> response_headers("text/plain; charset=utf-8")
        |> send_resp(403, "origin not allowed")
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

      lines =
        collect(fn send_line ->
          Connection.init_client(state.registry, state.max_line_bytes, send_line)
        end)

      Registry.pull(state.registry, self(), Connection.pull_batch())
      Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
      push(lines, state)
    end

    @impl true
    def handle_in({payload, opcode: :text}, state)
        when byte_size(payload) <= state.max_line_bytes do
      lines = collect(&Connection.run_command(payload, state.registry, &1, state.max_line_bytes))
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
      lines = collect(&Connection.emit(notification, state.registry, state.max_line_bytes, &1))
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

    defp collect(fun) do
      key = {__MODULE__, make_ref()}
      Process.put(key, [])

      try do
        fun.(fn line ->
          Process.put(key, [line | Process.get(key)])
          :ok
        end)

        key |> Process.get() |> Enum.reverse()
      after
        Process.delete(key)
      end
    end

    defp push([], state), do: {:ok, state}
    defp push(lines, state), do: {:push, Enum.map(lines, &{:text, &1}), state}
  end
end
