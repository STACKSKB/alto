defmodule Alto.Listeners.UnixSocket do
  @moduledoc """
  The v1 dogfood transport (the protocol contract): a Unix domain socket speaking
  NDJSON envelopes.

  The listener process binds `{:local, path}`, chmods the socket to `0600`
  inside a `0700` directory, and hands each accepted connection to a client
  process. Client processes own their socket, decode commands through
  `Alto.Protocol`, forward them to the `Alto.FrontEnd.Registry`, and encode
  registry notifications back onto the wire, pulling for more as they drain.
  A line over `max_line_bytes` closes the connection rather than truncating
  it — truncating a stream that carries approval decisions is unsafe, and
  closing is the fail-closed behavior.

  A stale socket file at `path` (an unclean shutdown's leftover, detected
  by a refused probe connection) is removed before binding; a live socket
  fails the start as `already_in_use` and any other pre-existing file as
  `path_taken`. The filesystem boundary (0700 directory,
  0600 socket) is the authentication for the single-user v1 default.
  """

  use GenServer

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection

  @default_max_line_bytes 1_048_576

  ## Client API

  @doc """
  Start the listener. Options:

    * `:registry` — the `Alto.FrontEnd.Registry` server (required);
    * `:path` — Unix socket path (required);
    * `:max_line_bytes` — per-line bound (default 1 MiB);
    * `:name` — registered name of the listener process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## Listener implementation

  @impl true
  def init(opts) do
    # Supervisor shutdown must run terminate/2 to unlink the socket.
    Process.flag(:trap_exit, true)

    registry = Keyword.fetch!(opts, :registry)
    path = opts |> Keyword.fetch!(:path) |> Path.expand()
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    with :ok <- prepare_socket_path(path),
         {:ok, listen_socket} <-
           :gen_tcp.listen(0, [
             :binary,
             {:ip, {:local, to_charlist(path)}},
             {:backlog, 8},
             {:active, false},
             {:exit_on_close, true}
           ]),
         :ok <- File.chmod(path, 0o600) do
      acceptor = spawn_link(fn -> accept_loop(listen_socket, registry, max_line_bytes) end)

      {:ok,
       %{
         path: path,
         listen_socket: listen_socket,
         acceptor: acceptor,
         max_line_bytes: max_line_bytes
       }}
    else
      {:error, reason} ->
        {:stop, {:socket_bind_failed, path, reason}}
    end
  end

  defp prepare_socket_path(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      remove_stale_socket(path)
    end
  end

  defp remove_stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :other}} ->
        # OTP file info has no socket type: a Unix socket reports as
        # `:other`. Probe it instead of trusting the type — a refused
        # connection is a stale socket from an unclean shutdown and is
        # safe to remove; a live one is already in use; anything else is
        # left alone and fails the start.
        case :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}], 500) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:error, :already_in_use}

          {:error, :econnrefused} ->
            File.rm(path)

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _other} ->
        {:error, :path_taken}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_loop(listen_socket, registry, max_line_bytes) do
    case :gen_tcp.accept(listen_socket, :infinity) do
      {:ok, socket} ->
        client = spawn(fn -> client_init(socket, registry, max_line_bytes) end)

        case :gen_tcp.controlling_process(socket, client) do
          :ok -> :ok
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept_loop(listen_socket, registry, max_line_bytes)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen_socket, registry, max_line_bytes)
    end
  end

  @impl true
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state),
    do: {:stop, {:acceptor_stopped, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.path)
    :ok
  end

  ## Client process
  ##
  ## NDJSON framing (line splitting and the size bound) lives here; command
  ## dispatch and notification encoding are shared with the WebSocket
  ## transport through `Alto.Listeners.Connection`.

  defp client_init(socket, registry, max_line_bytes) do
    Connection.init_client(registry, max_line_bytes, fn line -> :gen_tcp.send(socket, line) end)

    :inet.setopts(socket, active: :once)
    Registry.pull(registry, self(), Connection.pull_batch())
    Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
    client_loop(socket, registry, max_line_bytes, "")
  end

  defp client_loop(socket, registry, max_line_bytes, buffer) do
    send_line = fn line -> :gen_tcp.send(socket, line) end

    receive do
      {:tcp, ^socket, data} ->
        case take_lines(buffer <> data, max_line_bytes, []) do
          {:ok, buffer, lines} ->
            Enum.each(lines, &Connection.run_command(&1, registry, send_line, max_line_bytes))
            :inet.setopts(socket, active: :once)
            client_loop(socket, registry, max_line_bytes, buffer)

          :line_too_large ->
            # Closing, not truncating: the sender violated the announced
            # bound and the stream may carry approval decisions.
            Registry.detach(registry, self())
            :gen_tcp.close(socket)
        end

      {:tcp_closed, ^socket} ->
        Registry.detach(registry, self())

      {:tcp_error, ^socket, _reason} ->
        Registry.detach(registry, self())
        :gen_tcp.close(socket)

      :alto_close ->
        Registry.detach(registry, self())
        :gen_tcp.close(socket)

      :alto_wakeup ->
        # Safety net for the pull model: a batch that drains an empty buffer
        # must not wait forever for the next notification to re-trigger.
        Registry.pull(registry, self(), Connection.pull_batch())
        Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
        client_loop(socket, registry, max_line_bytes, buffer)

      {:alto_notification, notification} ->
        Connection.emit(notification, registry, max_line_bytes, send_line)
        client_loop(socket, registry, max_line_bytes, buffer)
    end
  end

  defp take_lines(buffer, max_line_bytes, lines) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        if byte_size(line) > max_line_bytes do
          :line_too_large
        else
          take_lines(rest, max_line_bytes, [String.trim_trailing(line, "\r") | lines])
        end

      [incomplete] ->
        if byte_size(incomplete) > max_line_bytes do
          :line_too_large
        else
          {:ok, incomplete, Enum.reverse(lines)}
        end
    end
  end
end
