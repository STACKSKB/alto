alias Alto.TUI.{State, View, App}
alias ExRatatui.Event.Mouse

state = %State{
  textarea: ExRatatui.textarea_new(),
  config: Alto.Config.new(),
  run_options: [],
  catalog_opts: [],
  dimensions: {240, 70}
}

entries =
  for n <- 1..200,
      do: %{
        kind: :tool,
        text: "read_file file#{n}.ex ✓",
        detail: String.duplicate("a line of code and some more code\n", 50)
      }

state = State.put_entries(state, nil, entries)
{view, _} = :timer.tc(fn -> View.widgets(state, %{width: 240, height: 70}) end)
rect = View.layout(state, 240, 70).transcript

{down, {:noreply, state}} =
  :timer.tc(fn ->
    App.handle_event(%Mouse{kind: "down", button: "left", x: rect.x + 2, y: 3}, state)
  end)

{drag, {:noreply, state}} =
  :timer.tc(fn ->
    App.handle_event(%Mouse{kind: "drag", button: "left", x: rect.x + 30, y: 50}, state)
  end)

{edge, {:noreply, state}} =
  :timer.tc(fn ->
    App.handle_event(%Mouse{kind: "drag", button: "left", x: rect.x + 30, y: 1}, state)
  end)

{scroll, _} =
  :timer.tc(fn ->
    Alto.TUI.Selection.autoscroll(state.selection, state.selection.scroll.token)
  end)

IO.inspect(%{view_us: view, down_us: down, drag_us: drag, edge_us: edge, scroll_us: scroll})

for n <- 1..3 do
  state = %{state | selection: Alto.TUI.Selection.new()}

  {down, {:noreply, state}} =
    :timer.tc(fn ->
      App.handle_event(%Mouse{kind: "down", button: "left", x: rect.x + 2, y: 3}, state)
    end)

  {:noreply, state} =
    App.handle_event(%Mouse{kind: "drag", button: "left", x: rect.x + 30, y: 1}, state)

  {scroll, _} =
    :timer.tc(fn ->
      Alto.TUI.Selection.autoscroll(state.selection, state.selection.scroll.token)
    end)

  {stream, _} =
    :timer.tc(fn ->
      state
      |> State.append_assistant_delta(nil, "a streaming response #{n}")
      |> App.render(%{width: 240, height: 70})
    end)

  IO.inspect(%{warm_down_us: down, warm_scroll_us: scroll, streaming_drag_frame_us: stream})
end

# A large Markdown report exercises table layout while its final row streams.
rows =
  Enum.map_join(1..120, "\n", fn n ->
    "| #{n} | `file#{n}.ex` | " <> String.duplicate("Review evidence ", 10) <> " |"
  end)

report = "## Long review\n\n| # | File | Evidence |\n| --- | --- | --- |\n" <> rows
entries = [%{kind: :assistant, text: report}]
{cold, _} = :timer.tc(fn -> Alto.TUI.Transcript.render(entries, 160) end)
entries = [%{kind: :assistant, text: report <> " more streaming text"}]
{stream, rich} = :timer.tc(fn -> Alto.TUI.Transcript.render(entries, 160) end)
{warm, _} = :timer.tc(fn -> Alto.TUI.Transcript.render(entries, 160) end)

IO.inspect(%{
  report_cold_us: cold,
  report_stream_us: stream,
  report_cached_us: warm,
  rows: length(rich.lines)
})
