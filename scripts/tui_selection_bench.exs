# Run from the repository root: mix run scripts/tui_selection_bench.exs
# Measures event handling plus native rendering (not terminal-emulator latency).
alias Alto.TUI.Selection
alias ExRatatui.{CellSession, Style}
alias ExRatatui.Event.Mouse
alias ExRatatui.Layout.Rect
alias ExRatatui.Widgets.{Block, Paragraph}

for {w, h} <- [{160, 50}, {240, 70}] do
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
  # Warm the renderer before timing.
  Selection.event(Selection.new(), down, {w, h}, widgets)

  {start, {:handled, pressed}} =
    :timer.tc(fn -> Selection.event(Selection.new(), down, {w, h}, widgets) end)

  terminal = CellSession.new(w, h)

  samples =
    for n <- 1..120 do
      event = %{down | kind: "drag", x: min(w - 2, 10 + rem(n, 100)), y: 2 + rem(n, h - 4)}

      {us, _} =
        :timer.tc(fn ->
          {:handled, selected} = Selection.event(pressed, event, {w, h}, widgets)
          :ok = CellSession.draw(terminal, Selection.widgets(selected, widgets))
        end)

      us
    end
    |> Enum.sort()

  IO.inspect(%{
    viewport: {w, h},
    down_us: start,
    drag_median_us: Enum.at(samples, 60),
    drag_p95_us: Enum.at(samples, 114),
    drag_max_us: List.last(samples)
  })

  CellSession.close(terminal)
end
