defmodule Alto.Runner.Execution.Call do
  @moduledoc "Bounded, cancellable participant invocation used by runner hosts."

  @doc "Start a supervised participant that is terminated if its calling process dies."
  def start(fun) when is_function(fun, 0) do
    owner = self()

    Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
      guard_owner(owner)
      fun.()
    end)
  end

  @doc "Run with an owned server, stopping it on return or exception."
  def with_server(pid, fun) do
    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc """
  Return the participant's value under a deadline and cancellation boundary.
  Infrastructure failures return `{:error, {:participant_failed, reason}}`;
  cancellation returns `{:error, {:cancelled, reason}}`.
  """
  def run(_fun, timeout, _cancel_ref) when timeout <= 0,
    do: {:error, {:participant_failed, :timeout}}

  def run(fun, timeout, cancel_ref) when is_function(fun, 0) do
    %Task{ref: ref} = task = start(fun)

    receive do
      {^ref, value} ->
        Process.demonitor(ref, [:flush])
        value

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:participant_failed, reason}}

      {:alto_cancel, ^cancel_ref, reason} when not is_nil(cancel_ref) ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:cancelled, reason}}
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:participant_failed, :timeout}}
    end
  end

  defp guard_owner(owner) when is_pid(owner) do
    worker = self()
    guardian = spawn_link(fn -> owner_guard(owner, worker) end)

    receive do
      {:alto_owner_guard_ready, ^guardian} -> :ok
    end
  end

  @doc "Read one cooperative cancellation message, if present."
  def cancellation(nil), do: :continue

  def cancellation(ref) do
    receive do
      {:alto_cancel, ^ref, reason} -> {:cancelled, reason}
    after
      0 -> :continue
    end
  end

  defp owner_guard(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    if Process.alive?(owner) do
      send(worker, {:alto_owner_guard_ready, self()})

      receive do
        {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, _, _} -> :ok
      end
    else
      Process.exit(worker, :kill)
    end
  end
end
