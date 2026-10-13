defmodule Alto.Contrib.Socket.SSH do
  @moduledoc """
  Managed forwarding of a local Unix socket to a remote Unix socket over OpenSSH.

  The returned handle owns a private temporary directory.  Closing the handle,
  or the process which opened it exiting, closes OpenSSH and removes that
  directory.
  """

  use GenServer

  @options NimbleOptions.new!(
             owner: [type: :pid],
             port: [type: {:or, [nil, {:in, 1..65_535}]}],
             timeout: [type: {:in, 0..600_000}, default: 5_000],
             ssh: [type: {:custom, __MODULE__, :validate_executable, []}],
             max_diagnostics: [type: {:in, 0..1_048_576}, default: 4_096],
             keepalive_interval: [type: {:in, 0..86_400}, default: 15],
             keepalive_count: [type: {:in, 1..100}, default: 3]
           )

  defstruct [:pid, :path]

  @type handle :: %__MODULE__{pid: pid(), path: Path.t()}

  @doc "Starts an SSH Unix-socket forward and waits for its local listener."
  @spec open(String.t(), Path.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def open(host, remote_socket, opts \\ []) do
    with :ok <- validate_host(host),
         :ok <- validate_remote_socket(remote_socket),
         {:ok, opts} <- validate_options(opts),
         {:ok, ssh} <- resolve_ssh(opts),
         {:ok, dir, local_path} <- make_socket_dir(),
         {:ok, pid} <- start_link_process(host, remote_socket, local_path, opts, dir, ssh),
         result <- await_listener(pid, local_path, opts[:timeout]) do
      case result do
        :ok ->
          {:ok, %__MODULE__{pid: pid, path: local_path}}

        {:error, _} = error ->
          _ = close(%__MODULE__{pid: pid, path: local_path})
          error
      end
    end
  end

  @doc "Returns the local Unix socket path for a tunnel handle."
  @spec path(handle()) :: Path.t()
  def path(%__MODULE__{path: path}), do: path

  @doc "Closes a tunnel and removes its private temporary directory."
  @spec close(handle()) :: :ok
  def close(%__MODULE__{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp start_link_process(host, remote, local, opts, dir, ssh) do
    GenServer.start(
      __MODULE__,
      {host, remote, local, opts, dir, ssh, opts[:owner]}
    )
  end

  @impl true
  def init({host, remote, local, opts, dir, ssh, owner}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    args = ssh_args(host, remote, local, opts)

    try do
      port =
        Port.open(
          {:spawn_executable, ssh},
          [{:args, args}, :binary, :exit_status, :stderr_to_stdout]
        )

      {:ok,
       %{
         port: port,
         dir: dir,
         diagnostics: <<>>,
         exit_status: nil,
         max_diagnostics: opts[:max_diagnostics]
       }}
    rescue
      error in [ArgumentError] ->
        File.rm_rf(dir)
        {:stop, {:ssh_unavailable, Exception.message(error)}}
    end
  end

  defp ssh_args(host, remote, local, opts) do
    interval = opts[:keepalive_interval]
    count = opts[:keepalive_count]

    [
      "-N",
      "-T",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=#{interval}",
      "-o",
      "ServerAliveCountMax=#{count}",
      "-L",
      "#{local}:#{remote}",
      maybe_port(opts),
      host
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_port(opts) do
    if port = opts[:port], do: ["-p", Integer.to_string(port)]
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts),
      do: NimbleOptions.validate(Keyword.put_new(opts, :owner, self()), @options),
      else: {:error, :invalid_options}
  end

  @doc false
  def validate_executable(nil), do: {:ok, nil}

  def validate_executable(path) when is_binary(path) and byte_size(path) in 1..4_096,
    do: {:ok, path}

  def validate_executable(_), do: {:error, "expected an executable path of 1 to 4096 bytes"}

  defp resolve_ssh(opts) do
    case Keyword.get(opts, :ssh) || System.find_executable("ssh") do
      ssh when is_binary(ssh) ->
        if File.regular?(ssh), do: {:ok, ssh}, else: {:error, :ssh_unavailable}

      _ ->
        {:error, :ssh_unavailable}
    end
  end

  defp await_listener(pid, path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_until(pid, path, deadline)
  end

  defp await_until(pid, path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      Process.alive?(pid) ->
        case status(pid) do
          {nil, _} -> :wait
          {exit_status, diagnostic} -> {:error, {:ssh_exit, exit_status, diagnostic}}
        end
        |> case do
          :wait -> wait_or_timeout(pid, path, deadline)
          result -> result
        end

      true ->
        {:error, :ssh_exited}
    end
  end

  defp wait_or_timeout(pid, path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(10)
      await_until(pid, path, deadline)
    end
  end

  defp status(pid) do
    try do
      GenServer.call(pid, :status, 100)
    catch
      :exit, _ -> {0, <<>>}
    end
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, {state.exit_status, state.diagnostics}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply,
     %{state | diagnostics: append_diagnostics(state.diagnostics, data, state.max_diagnostics)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{state | exit_status: status}}
  end

  def handle_info({:DOWN, _ref, :process, _owner, _reason}, state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port, dir: dir}) do
    terminate_port(port)
    File.rm_rf(dir)
    :ok
  end

  defp terminate_port(port) do
    # Port.close/1 can leave an executable that traps hangup running. Signal
    # the exact child attached to this port before closing the port.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp append_diagnostics(existing, data, max) do
    data = IO.iodata_to_binary(data)
    combined = existing <> data

    if byte_size(combined) > max,
      do: binary_part(combined, byte_size(combined) - max, max),
      else: combined
  end

  defp make_socket_dir do
    dir =
      Path.join(System.tmp_dir!(), "alto_resident-ssh-#{random_suffix()}")

    case File.mkdir(dir) do
      :ok ->
        case {File.chmod(dir, 0o700), ensure_absent(Path.join(dir, "forward.sock"))} do
          {:ok, :ok} ->
            {:ok, dir, Path.join(dir, "forward.sock")}

          {chmod_result, absent_result} ->
            File.rm_rf(dir)
            if chmod_result != :ok, do: chmod_result, else: absent_result
        end

      error ->
        error
    end
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, :socket_already_exists}, else: :ok
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp validate_host(host) when is_binary(host) and byte_size(host) > 0 do
    if host =~ ~r/^[\s-]/ or String.match?(host, ~r/\s/) or
         String.match?(host, ~r/[\x00-\x1F\x7F]/),
       do: {:error, :invalid_host},
       else: :ok
  end

  defp validate_host(_), do: {:error, :invalid_host}

  defp validate_remote_socket(path) when is_binary(path) do
    if Path.type(path) != :absolute or path =~ ~r/[:\x00-\x1F\x7F\s]/,
      do: {:error, :invalid_remote_socket},
      else: :ok
  end

  defp validate_remote_socket(_), do: {:error, :invalid_remote_socket}
end
