# Run from the repository root: mix run scripts/tui_selection_bench.exs
# Measures event handling plus native rendering (not terminal-emulator latency).
alias Alto.TUI.Selection
alias ExRatatui.{CellSession, Style}
alias ExRatatui.Event.Mouse
alias ExRatatui.Layout.Rect
alias ExRatatui.Widgets.{Block, Paragraph}

for {w, h} <- [{160, 50}, {240, 70}, {400, 120}] do
  lines =
    Enum.map_join(1..h, "\n", fn n ->
      "#{n} " <> String.duplicate("sample 猫 text ", div(w, 14))
    end)

  widgets = fn ->
    [
      {%Paragraph{
         text: lines,
         block: %Block{title: "Transcript", borders: [:all]},
         style: %Style{fg: :white}
       }, %Rect{width: w, height: h}}
    ]
  end

  down = %Mouse{kind: "down", button: "left", x: 1, y: 1}
  # A running TUI has already initialized and painted its native renderer.
  terminal = CellSession.new(w, h)
  :ok = CellSession.draw(terminal, widgets.())
  # Report first selection capture separately from reuse of its native buffers.
  {cold_start, _} = :timer.tc(fn -> Selection.event(Selection.new(), down, {w, h}, widgets) end)

  {start, {:handled, pressed}} =
    :timer.tc(fn -> Selection.event(Selection.new(), down, {w, h}, widgets) end)

  {down_draw, :ok} =
    :timer.tc(fn -> CellSession.draw(terminal, Selection.widgets(pressed, widgets)) end)

  samples =
    for n <- 1..120 do
      event = %{down | kind: "drag", x: min(w - 2, 10 + rem(n, 100)), y: 2 + rem(n, h - 4)}

      {event_us, {:handled, selected}} =
        :timer.tc(fn -> Selection.event(pressed, event, {w, h}, widgets) end)

      {draw_us, :ok} =
        :timer.tc(fn -> CellSession.draw(terminal, Selection.widgets(selected, widgets)) end)

      {event_us + draw_us, event_us}
    end
    |> Enum.sort()

  IO.inspect(%{
    viewport: {w, h},
    cold_capture_us: cold_start,
    down_us: start,
    down_frame_us: start + down_draw,
    drag_median_us: elem(Enum.at(samples, 60), 0),
    drag_p95_us: elem(Enum.at(samples, 114), 0),
    drag_max_us: elem(List.last(samples), 0),
    highlight_median_us: samples |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(60)
  })

  burst =
    for n <- 1..200,
        do: %{down | kind: "drag", x: if(rem(n, 2) == 0, do: w - 2, else: 2), y: h - 2}

  Process.put(:selection_benchmark_input, burst)

  poll = fn ->
    case Process.get(:selection_benchmark_input) do
      [next | rest] ->
        Process.put(:selection_benchmark_input, rest)
        next

      [] ->
        nil
    end
  end

  {burst_us, _} =
    :timer.tc(fn ->
      latest = Alto.TUI.DragInput.latest(%{down | kind: "drag"}, poll)
      {:handled, selected} = Selection.event(pressed, latest, {w, h}, widgets)
      :ok = CellSession.draw(terminal, Selection.widgets(selected, widgets))
    end)

  IO.inspect(%{viewport: {w, h}, queued_motion_events: 200, coalesced_frame_us: burst_us})
  Process.delete(:selection_benchmark_input)

  CellSession.close(terminal)
end

# Scrolling deep into a long transcript must not reflow its hidden history while dragging.
for count <- [200, 2_000, 10_000] do
  widgets = fn ->
    [
      {%Paragraph{
         text: String.duplicate("a moderately long line of transcript content\n", count),
         wrap: true,
         scroll: {count - 60, 0}
       }, %Rect{width: 180, height: 60}}
    ]
  end

  down = %Mouse{kind: "down", button: "left", x: 0, y: 0}

  {press, {:handled, selection}} =
    :timer.tc(fn -> Selection.event(Selection.new(), down, {180, 60}, widgets) end)

  {:handled, selection} =
    Selection.event(selection, %{down | kind: "drag", x: 179, y: 59}, {180, 60}, widgets)

  terminal = CellSession.new(180, 60)

  samples =
    for _ <- 1..30 do
      {time, :ok} =
        :timer.tc(fn -> CellSession.draw(terminal, Selection.widgets(selection, widgets)) end)

      time
    end

  IO.inspect(%{
    history_rows: count,
    down_us: press,
    drag_render_median_us: samples |> Enum.sort() |> Enum.at(15)
  })

  CellSession.close(terminal)
end
