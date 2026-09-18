defmodule Alto.External.Process do
  @moduledoc """
  Bounded process groups for commands and line based external clients.

  The startup shell announces readiness and waits for an explicit release before
  executing user code. OTP's Unix port launcher normally creates a new session;
  we verify that the child is its own process-group leader before enabling group
  signals. No signal is sent to an unverified process group.

  The linked watchdog cleans up on owner exit while the VM is alive. This is not
  a guarantee against a hard VM or machine crash; use an OS-managed sandbox or
  service boundary when descendants must not outlive such failures.
  """

  @enforce_keys [:port, :os_pid, :group_kill, :watchdog]
  defstruct [:port, :os_pid, :group_kill, :watchdog]

  @ready "alto-process-ready\n"

  require Logger

  @spec open(Path.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def open(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    case File.stat(executable) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        open_port(executable, args, opts)

      {:ok, _} ->
        {:error, {:process_open_failed, :eacces}}

      {:error, reason} ->
        {:error, {:process_open_failed, reason}}
    end
  end

  defp open_port(executable, args, opts) do
    started_ms = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :startup_timeout, 30_000)
    deadline_ms = started_ms + timeout
    {port_executable, port_args, group_kill} = trampoline(executable, args)

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

    case start_child(port, group_kill, deadline_ms) do
      {:ok, os_pid, watchdog} ->
        {:ok, %__MODULE__{port: port, os_pid: os_pid, group_kill: group_kill, watchdog: watchdog}}

      {:error, _} = error ->
        if Port.info(port), do: Port.close(port)
        error
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:process_open_failed, Exception.message(error)}}
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

  @doc false
  def resolve_executable(command) when is_binary(command) do
    System.find_executable(command) || if(File.regular?(command), do: Path.expand(command))
  end

  defp encode_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp encode_env(_), do: []

  defp trampoline(executable, args) do
    case {System.find_executable("sh"), System.find_executable("kill")} do
      {shell, kill} when is_binary(shell) and is_binary(kill) ->
        script =
          "printf 'alto-process-ready\\n'; IFS= read -r release || exit; [ \"$release\" = release ] || exit; exec \"$@\""

        {shell, ["-c", script, "alto-process", executable | args], kill}

      _ ->
        warn_degraded_once()
        {executable, args, nil}
    end
  end

  defp warn_degraded_once do
    key = {__MODULE__, :degraded_warning}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.warning("Alto process cleanup degraded: process-group cleanup is unavailable")
    end
  end

  defp start_child(port, nil, _deadline), do: {:ok, port_pid(port), nil}

  defp start_child(port, kill, deadline) do
    with :ok <- await_ready(port, deadline, ""),
         pid when is_integer(pid) <- port_pid(port),
         :ok <- verify_group(pid) do
      watchdog = watch_owner(pid, kill)

      if Port.command(port, "release\n") do
        {:ok, pid, watchdog}
      else
        kill_group(pid, kill)
        disarm_watchdog(watchdog)
        {:error, :process_exited_before_start}
      end
    else
      nil -> {:error, :process_exited_before_start}
      error -> error
    end
  end

  defp port_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp await_ready(port, deadline, prefix) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        value = prefix <> data

        cond do
          value == @ready ->
            :ok

          byte_size(value) < byte_size(@ready) and String.starts_with?(@ready, value) ->
            await_ready(port, deadline, value)

          true ->
            {:error, :invalid_process_handshake}
        end

      {^port, {:exit_status, _}} ->
        {:error, :process_exited_before_start}
    after
      timeout -> {:error, :process_group_setup_timeout}
    end
  end

  defp verify_group(pid) do
    if process_group(pid) == pid, do: :ok, else: {:error, :unverified_process_group}
  end

  defp process_group(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        # comm can contain spaces and parentheses; numeric fields follow its last ')'.
        [_state, _parent, group | _] = stat |> String.split(") ") |> List.last() |> String.split()
        String.to_integer(group)

      {:error, _} ->
        case System.find_executable("ps") do
          nil ->
            nil

          ps ->
            case System.cmd(ps, ["-o", "pgid=", "-p", Integer.to_string(pid)],
                   stderr_to_stdout: true
                 ) do
              {output, 0} -> output |> String.trim() |> String.to_integer()
              _ -> nil
            end
        end
    end
  rescue
    _ -> nil
  end

  defp watch_owner(pid, kill) do
    owner = self()
    ready = make_ref()

    watchdog =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        monitor = Process.monitor(owner)
        send(owner, {ready, self()})

        receive do
          {:disarm, ^owner} ->
            Process.unlink(owner)
            Process.demonitor(monitor, [:flush])

          {:DOWN, ^monitor, :process, ^owner, _} ->
            kill_group(pid, kill)

          {:EXIT, ^owner, _} ->
            kill_group(pid, kill)
        end
      end)

    receive do: ({^ready, ^watchdog} -> Process.link(watchdog))
    watchdog
  end

  defp disarm_watchdog(nil), do: :ok

  defp disarm_watchdog(watchdog) do
    send(watchdog, {:disarm, self()})
    :ok
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
