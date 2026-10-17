defmodule Alto.TUI.History do
  @moduledoc "Cancellable background hydration; navigation never waits for saved history."
  alias Alto.TUI.State

  def request(state, task) do
    id = task["id"]

    if state.history_load && (state.history_load.id == id or queued_load?(state)) do
      state
    else
      state = cancel(state)
      session = task["conversation_id"]
      plan = load_plan(state, task)

      if plan != [] do
        owner = self()
        token = make_ref()
        opts = state.catalog_opts

        # Capture only identifiers/options, not the entire UI state or its caches.
        {pid, monitor} =
          spawn_monitor(fn ->
            Enum.each(plan, fn {kind, load} ->
              send(owner, {:tui_history, token, kind, load.(session, opts)})
            end)
          end)

        %{state | history_load: %{id: id, token: token, pid: pid, monitor: monitor}}
      else
        state
      end
    end
  end

  def hydrate(state, task) do
    Enum.reduce(load_plan(state, task), state, fn {kind, load}, next ->
      put_result(
        next,
        state.selected_task_id,
        kind,
        load.(task && task["conversation_id"], state.catalog_opts)
      )
    end)
  end

  defp load_plan(state, task) do
    id = (task && task["id"]) || state.selected_task_id
    session = task && task["conversation_id"]
    backend = task && State.task_backend(task)
    native? = is_binary(session) and Alto.TUI.Backend.runner?(state.run_options, backend)

    usage? =
      not Map.has_key?(state.usage, id) and is_binary(session) and
        Alto.TUI.Backend.ui(%{state | selected_backend: backend}, :session_usage?) == true

    # Accounting precedes entries: publishing entries can release a queued follow-up.
    [
      {:usage, if(usage?, do: &State.load_session_usage/2)},
      {:entries, if(native?, do: &State.load_session_entries/2, else: fn _, _ -> [] end)},
      {:subagents, if(native?, do: &Alto.TUI.Subagents.load/2)}
    ]
    |> Enum.reject(fn {kind, load} ->
      is_nil(load) or Map.has_key?(Map.fetch!(state, kind), id)
    end)
  end

  def cancel(%{history_load: nil} = state), do: state

  def cancel(state), do: if(queued_load?(state), do: state, else: stop(state))

  def stop(%{history_load: nil} = state), do: state

  def stop(state) do
    Process.exit(state.history_load.pid, :kill)
    Process.demonitor(state.history_load.monitor, [:flush])
    %{state | history_load: nil}
  end

  def loading_entries?(state, id),
    do:
      state.history_load != nil and state.history_load.id == id and
        not Map.has_key?(state.entries, id)

  defp queued_load?(state),
    do:
      state.history_load != nil and loading_entries?(state, state.history_load.id) and
        State.input_pending?(state, state.history_load.id)

  def apply(state, token, kind, value) do
    case state.history_load do
      %{token: ^token, id: id} ->
        put_result(state, id, kind, value)

      _ ->
        state
    end
  end

  # Live input/events take precedence over a snapshot loaded before them.
  defp put_result(state, id, :entries, value),
    do: State.put_entries(state, id, value ++ State.task_entries(state, id))

  defp put_result(state, id, :usage, value),
    do: %{state | usage: Map.update(state.usage, id, value, &Alto.Usage.merge(value, &1))}

  defp put_result(state, id, :subagents, value),
    do: State.restore_subagents(state, id, value)
end
