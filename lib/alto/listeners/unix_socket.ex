defmodule Alto.Listeners.UnixSocket do
  @moduledoc """
  Unix-domain NDJSON transport with bounded OTP line framing.

  The socket is `0600` inside a `0700` directory. A refused probe identifies
  a stale socket; live sockets and other existing files are never replaced.
  ThousandIsland owns acceptance, connection supervision and socket cleanup;
  `Alto.Listeners.Connection` owns protocol dispatch and notification encoding.
  """
  use GenServer
  alias Alto.Listeners.Connection

  @doc "Start with required :registry and :path, optional :name and :max_line_bytes (1 MiB)."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = opts |> Keyword.fetch!(:path) |> Path.expand()
    limit = Keyword.get(opts, :max_line_bytes, Connection.default_max_line_bytes())

    with :ok <- prepare_socket_path(path),
         {:ok, server} <-
           ThousandIsland.start_link(
             port: 0,
             num_acceptors: 1,
             read_timeout: :infinity,
             shutdown_timeout: 1_000,
             handler_module: __MODULE__.Handler,
             handler_options: {Keyword.fetch!(opts, :registry), limit},
             transport_options: [
               ip: {:local, to_charlist(path)},
               backlog: 8,
               packet: :line,
               packet_size: limit + 1,
               buffer: limit + 1
             ]
           ),
         :ok <- File.chmod(path, 0o600) do
      {:ok, %{path: path, server: server}}
    else
      {:error, reason} -> {:stop, {:socket_bind_failed, path, reason}}
    end
  end

  @impl true
  def handle_info({:EXIT, server, reason}, %{server: server} = state),
    do: {:stop, {:listener_stopped, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    File.rm(state.path)
    if Process.alive?(state.server), do: Supervisor.stop(state.server)
    :ok
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

  defmodule Handler do
    @moduledoc false
    use ThousandIsland.Handler
    alias Alto.FrontEnd.Registry
    alias Alto.Listeners.Connection
    alias ThousandIsland.Socket

    @impl true
    def handle_connection(socket, {registry, limit} = state) do
      :ok = Socket.send(socket, Connection.hello_lines(registry, limit))
      send(self(), :alto_wakeup)
      {:continue, state}
    end

    @impl true
    def handle_data(line, socket, {registry, limit} = state) do
      # OTP can truncate at the buffer bound; never dispatch a fragment.
      if byte_size(line) <= limit + 1 and String.ends_with?(line, "\n") do
        line = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
        :ok = Socket.send(socket, Connection.command_lines(line, registry, limit))
        {:continue, state}
      else
        {:close, state}
      end
    end

    @impl true
    def handle_info(:alto_wakeup, {socket, {registry, _} = state}) do
      Registry.pull(registry, self(), Connection.pull_batch())
      Process.send_after(self(), :alto_wakeup, Connection.wakeup_ms())
      {:noreply, {socket, state}}
    end

    def handle_info(:alto_close, state), do: {:stop, :normal, state}

    def handle_info({:alto_notification, notification}, {socket, {registry, limit} = state}) do
      :ok = Socket.send(socket, Connection.notification_lines(notification, registry, limit))
      {:noreply, {socket, state}}
    end
  end
end
