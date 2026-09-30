# From packages/alto_tui:
# mix run ../../scripts/tui_navigation_bench.exs sess-... sess-...
# Reads existing history and may refresh disposable .cache projections.
# Does not change the catalog or start model runs.
# Measures mouse transitions + native drawing, excluding terminal-emulator latency.
alias Alto.TUI.{App, State}
alias ExRatatui.{CellSession, Event.Mouse}

Code.ensure_loaded!(Alto.TUI.Backends.Native)
{:ok, projects, tasks} = Alto.TUI.Catalog.navigation()
ids = System.argv()
if ids == [], do: raise("pass two or more saved session IDs")

selected =
  for id <- ids do
    Enum.find(List.flatten(Map.values(tasks)), &(&1["conversation_id"] == id)) ||
      raise("session is not attached to a saved task: #{id}")
  end

project = Enum.find(projects, &(&1["id"] == hd(selected)["project_id"]))
selected = Enum.map(selected, &Map.put(&1, "project_id", project["id"]))

state = %State{
  textarea: ExRatatui.textarea_new(),
  run_options: [tui_backends: [alto: {Alto.TUI.Backends.Native, []}]],
  catalog_opts: [],
  projects: [project],
  tasks: %{project["id"] => selected},
  selected_project_id: project["id"],
  selected_backend: :alto,
  dimensions: {180, 50},
  async_history?: true
}

terminal = CellSession.new(180, 50)
paint = fn state -> CellSession.draw(terminal, App.render(state, %{width: 180, height: 50})) end
paint.(state)

wait = fn recur, state, id, started, ready ->
  if state.history_load do
    receive do
      message ->
        result = App.handle_info(message, state)
        next = elem(result, 1)
        paint.(next)

        ready =
          ready ||
            if(Map.has_key?(next.entries, id), do: System.monotonic_time(:microsecond) - started)

        recur.(recur, next, id, started, ready)
    after
      15_000 -> raise("history loading timed out")
    end
  else
    {state, ready}
  end
end

Enum.reduce(selected ++ selected, state, fn task, state ->
  index = Enum.find_index(State.rail_rows(state), &(&1.id == task["id"]))
  mouse = %Mouse{kind: "down", button: "left", x: 5, y: index + 2}
  started = System.monotonic_time(:microsecond)
  {:noreply, pressed} = App.handle_event(mouse, state)
  paint.(pressed)
  {:noreply, state} = App.handle_event(%{mouse | kind: "up"}, pressed)
  paint.(state)
  feedback = System.monotonic_time(:microsecond) - started
  ready = if Map.has_key?(state.entries, task["id"]), do: feedback
  {state, ready} = wait.(wait, state, task["id"], started, ready)

  IO.inspect(%{
    session: task["conversation_id"],
    selection_frame_ms: feedback / 1000,
    transcript_frame_ms: ready / 1000,
    details_ready_ms: (System.monotonic_time(:microsecond) - started) / 1000
  })

  state
end)

CellSession.close(terminal)
