defmodule Alto.Contrib.Resident.Connection do
  @moduledoc """
  Owner-bound reconnecting service client. All network work stays in this process.
  Only repeatable reads reconnect automatically; commands execute once. The owner
  receives bounded Console snapshots and must review uncertain send outcomes.
  """
  use GenServer
  alias Alto.Contrib.Resident.Console

  def start(owner, options), do: GenServer.start(__MODULE__, {owner, options})
  def action(pid, action), do: GenServer.cast(pid, {:action, action})

  @impl true
  def init({owner, options}) do
    send(self(), :poll)

    {:ok,
     %{owner: owner, monitor: Process.monitor(owner), model: Console.new(options), delay: 250}}
  end

  @impl true
  def handle_cast({:action, action}, state), do: {:noreply, perform(state, action)}

  def handle_cast({:complete, path}, state) do
    result = Console.complete_folders(state.model, path)
    send(state.owner, {:alto_resident_folders, self(), path, result})
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    action = if state.model.client, do: :poll, else: :connect
    next = perform(state, action)
    delay = if next.model.client, do: 250, else: min(state.delay * 2, 10_000)
    Process.send_after(self(), :poll, delay)
    {:noreply, %{next | delay: delay}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: Console.close(state.model)

  defp perform(state, action) do
    model = Console.perform(state.model, action, self())
    send(state.owner, {:alto_resident_snapshot, self(), action, model})
    %{state | model: model}
  end
end
