defmodule Alto.External.Process do
  @moduledoc "Bounded process groups for commands and line based external clients."

  @enforce_keys [:port, :os_pid, :group_kill, :watchdog]
  defstruct [:port, :os_pid, :group_kill, :watchdog]

  @os_pid_wait_ms 1_000

  require Logger

  @spec open(Path.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def open(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    started_ms = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :startup_timeout, Keyword.get(opts, :timeout_ms, 30_000))
    deadline_ms = started_ms + timeout
    {port_executable, port_args, group_kill, observer} = trampoline(executable, args)

    port_opts =
      [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        {:args, port_args},
        {:cd, Keyword.get(opts, :cwd, File.cwd!())},
        {:env, encode_env(Keyword.get(opts, :env, %{}))}
      ] ++ if(Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout], else: [])

    port =
      Port.open(
        {:spawn_executable, port_executable},
        port_opts
      )

    os_pid = await_os_pid(port, min(started_ms + @os_pid_wait_ms, deadline_ms))
    watchdog = watch_owner(os_pid, group_kill)

    case resume(os_pid, group_kill, observer, deadline_ms) do
      :ok ->
        {:ok, %__MODULE__{port: port, os_pid: os_pid, group_kill: group_kill, watchdog: watchdog}}

      {:error, _reason} = error ->
        close(%__MODULE__{port: port, os_pid: os_pid, group_kill: group_kill, watchdog: watchdog})
        error
    end
  rescue
    error in ArgumentError -> {:error, {:process_open_failed, Exception.message(error)}}
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{} = process) do
    kill_group(process.os_pid, process.group_kill)
    if Port.info(process.port), do: Port.close(process.port)
    disarm_watchdog(process.watchdog)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def port(%__MODULE__{port: port}), do: port

  defp encode_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp encode_env(_), do: []

  defp trampoline(executable, args) do
    case {System.find_executable("sh"), System.find_executable("kill"), stop_observer()} do
      {shell, kill, observer}
      when is_binary(shell) and is_binary(kill) and not is_nil(observer) ->
        {shell, ["-c", "kill -STOP $$; exec \"$@\"", "alto-process", executable | args], kill,
         observer}

      _other ->
        Logger.warning(
          "Alto process cleanup degraded: process-group cleanup is unavailable; command runs without group cleanup"
        )

        {executable, args, nil, nil}
    end
  end

  defp await_os_pid(port, deadline_ms) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        os_pid

      nil ->
        cond do
          is_nil(Port.info(port)) ->
            nil

          System.monotonic_time(:millisecond) < deadline_ms ->
            Process.sleep(1)
            await_os_pid(port, deadline_ms)

          true ->
            nil
        end
    end
  end

  defp stop_observer do
    cond do
      File.regular?("/proc/self/status") -> :procfs
      ps = System.find_executable("ps") -> {:ps, ps}
      true -> nil
    end
  end

  defp watch_owner(_os_pid, nil), do: nil

  defp watch_owner(os_pid, group_kill) do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:disarm, ^owner} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^owner, _reason} -> kill_group(os_pid, group_kill)
      end
    end)
  end

  defp disarm_watchdog(nil), do: :ok
  defp disarm_watchdog(watchdog), do: send(watchdog, {:disarm, self()}) && :ok

  defp resume(os_pid, kill, observer, deadline_ms)
       when is_integer(os_pid) and is_binary(kill) do
    with :ok <- await_stopped(os_pid, observer, deadline_ms) do
      case System.cmd(kill, ["-CONT", Integer.to_string(os_pid)], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:process_resume_failed, status, output}}
      end
    end
  rescue
    error -> {:error, {:process_resume_failed, Exception.message(error)}}
  end

  defp resume(_os_pid, nil, nil, _deadline_ms), do: :ok
  defp resume(nil, _kill, _observer, _deadline_ms), do: {:error, :process_exited_before_start}

  defp await_stopped(os_pid, observer, deadline_ms) do
    case process_state(os_pid, observer) do
      state when state in ["T", "t"] ->
        :ok

      nil ->
        {:error, :process_exited_before_start}

      _state ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(1)
          await_stopped(os_pid, observer, deadline_ms)
        else
          {:error, :process_group_setup_timeout}
        end
    end
  end

  defp process_state(os_pid, :procfs) do
    with {:ok, status} <- File.read("/proc/#{os_pid}/status"),
         line when is_binary(line) <-
           Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "State:")),
         [_label, state | _rest] <- String.split(line) do
      state
    else
      _other -> nil
    end
  end

  defp process_state(os_pid, {:ps, ps}) do
    case System.cmd(ps, ["-o", "state=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.first()
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp kill_group(os_pid, kill) when is_integer(os_pid) and is_binary(kill) do
    System.cmd(kill, ["-KILL", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp kill_group(_os_pid, _kill), do: :ok

  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer() | nil,
          group_kill: binary() | nil,
          watchdog: pid() | nil
        }
end
