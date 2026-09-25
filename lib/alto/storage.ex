defmodule Alto.Storage do
  @moduledoc false

  @doc "Resolve the storage root; callers may override their own directory explicitly."
  def state_home do
    case System.get_env("ALTO_STATE_HOME") do
      path when is_binary(path) and path != "" ->
        path

      _other ->
        case System.get_env("XDG_STATE_HOME") do
          path when is_binary(path) and path != "" -> path
          _other -> Path.join(System.user_home!(), ".local/state")
        end
    end
  end

  @default_lock_timeout 5_000
  @ready "__alto_lock_ready__\n"

  @doc "Run `fun` while holding an OS advisory lock for `path`."
  @spec with_lock(Path.t(), keyword(), (-> term())) :: term()
  def with_lock(path, opts \\ [], fun) when is_binary(path) and is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_lock_timeout)
    lock_path = Path.expand(path)

    with {:ok, port} <- acquire(lock_path, opts) do
      try do
        fun.()
      after
        do_release(port)
      end
    else
      {:error, {:timeout, timeout}} -> {:error, {:storage_lock_timeout, lock_path, timeout}}
      {:error, :timeout} -> {:error, {:storage_lock_timeout, lock_path, timeout}}
      {:error, reason} -> {:error, {:storage_lock_failed, lock_path, reason}}
    end
  end

  @doc "Acquire an OS advisory lock and return its owning port."
  @spec acquire(Path.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def acquire(path, opts \\ []) when is_binary(path) do
    timeout = Keyword.get(opts, :timeout, @default_lock_timeout)
    lock_path = Path.expand(path)

    with :ok <- ensure_lock_file(lock_path), do: open_lock(lock_path, timeout)
  end

  @doc "Replay under a lifetime lock, then transfer ownership to the new server."
  def start_server(module, state, load, opts) do
    with {:ok, lock} <-
           acquire(state.path <> ".lock", timeout: Keyword.get(opts, :lock_timeout, 5_000)) do
      result =
        with {:ok, loaded} <- load.(state),
             {:ok, pid} <-
               GenServer.start_link(module, %{loaded | lock: lock},
                 name: Keyword.get(opts, :name, module)
               ) do
          case connect(lock, pid) do
            :ok ->
              {:ok, pid}

            {:error, _} = error ->
              GenServer.stop(pid)
              error
          end
        end

      case result do
        {:ok, _pid} ->
          result

        error ->
          release(lock)
          error
      end
    end
  end

  @doc "Transfer an acquired lock to its long-lived owner process."
  @spec connect(port(), pid()) :: :ok | {:error, term()}
  def connect(port, pid) when is_pid(pid) do
    if Port.connect(port, pid), do: :ok, else: {:error, :lock_connect_failed}
  rescue
    error -> {:error, {:lock_connect_failed, Exception.message(error)}}
  end

  @doc "Release an acquired lock."
  @spec release(port()) :: :ok
  def release(port), do: do_release(port)

  @doc "Create a private directory; pass `owned: true` to tighten an existing one."
  @spec ensure_private_dir(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_private_dir(dir, opts \\ []) when is_binary(dir) do
    if File.dir?(dir) do
      if Keyword.get(opts, :owned, false), do: File.chmod(dir, 0o700), else: :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  @doc "Create a private state file and ensure its mode is owner-only."
  @spec ensure_private_file(Path.t()) :: :ok | {:error, term()}
  def ensure_private_file(path) when is_binary(path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = File.close(io)
        if result == :ok, do: File.chmod(path, 0o600), else: result

      {:error, :eexist} ->
        File.chmod(path, 0o600)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_lock_file(path) do
    with :ok <- ensure_private_dir(Path.dirname(path)), do: ensure_private_file(path)
  end

  defp open_lock(path, timeout) do
    case System.find_executable("flock") do
      nil ->
        {:error, :flock_unavailable}

      executable ->
        # Cross-VM writers need an OS lock, not a BEAM-local mutex. --no-fork
        # replaces flock with the waiting shell, which retains the lock fd.
        command = "exec 2>/dev/null; printf '#{@ready}'; IFS= read -r _"
        wait = timeout_seconds(timeout)

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            {:args, ["-F", "-x", "-w", wait, path, "-c", command]}
          ])

        await_ready(port, System.monotonic_time(:millisecond) + timeout, <<>>)
    end
  end

  defp await_ready(port, deadline, buffer) do
    receive do
      {^port, {:data, data}} ->
        case buffer <> data do
          <<@ready::binary, _rest::binary>> -> {:ok, port}
          next -> await_ready(port, deadline, next)
        end

      {^port, {:exit_status, 1}} ->
        {:error, :timeout}

      {^port, {:exit_status, status}} ->
        {:error, {:lock_process_exit, status}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        close_port(port)
        {:error, :timeout}
    end
  end

  # The OS process can exit at the timeout boundary before its exit-status
  # message is received. Closing an already closed port is harmless cleanup.
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp timeout_seconds(timeout), do: :erlang.float_to_binary(timeout / 1_000, decimals: 3)

  defp do_release(port) do
    if Port.command(port, "release\n") do
      await_exit(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> await_exit(port)
    after
      1_000 -> Port.close(port)
    end
  end
end
