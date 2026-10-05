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
      entries? = not Map.has_key?(state.entries, id)

      usage? =
        not Map.has_key?(state.usage, id) and Alto.TUI.Backend.ui(state, :session_usage?) == true

      children? = not Map.has_key?(state.subagents, id)

      if entries? or usage? or children? do
        owner = self()
        token = make_ref()
        opts = state.catalog_opts

        # Capture only identifiers/options, not the entire UI state or its caches.
        {pid, monitor} =
          spawn_monitor(fn ->
            # Read accounting before publishing the transcript. A queued follow-up
            # starts only after :entries, so replay cannot double-count its events.
            if usage?,
              do:
                send(
                  owner,
                  {:tui_history, token, :usage, State.load_session_usage(session, opts)}
                )

            if entries?,
              do:
                send(
                  owner,
                  {:tui_history, token, :entries, State.load_session_entries(session, opts)}
                )

            if children?,
              do:
                send(
                  owner,
                  {:tui_history, token, :subagents, Alto.TUI.Subagents.load(session, opts)}
                )
          end)

        %{state | history_load: %{id: id, token: token, pid: pid, monitor: monitor}}
      else
        state
      end
    end
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
        # Live input/events take precedence over a snapshot loaded before them.
        case kind do
          :entries ->
            State.put_entries(state, id, value ++ State.task_entries(state, id))

          :usage ->
            %{state | usage: Map.update(state.usage, id, value, &Alto.Usage.merge(value, &1))}

          :subagents ->
            {agents, warnings} = value
            current = Map.get(state.subagents, id, %{})

            state = State.put_subagents(state, id, Map.merge(agents, current))

            %{
              state
              | notice:
                  if(warnings == [], do: state.notice, else: Enum.join(Enum.uniq(warnings), "; "))
            }
        end

      _ ->
        state
    end
  end
end
