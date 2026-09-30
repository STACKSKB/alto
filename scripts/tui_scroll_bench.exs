# From packages/alto_tui: mix run ../../scripts/tui_scroll_bench.exs
# Synthetic history only; no saved sessions, catalog writes, or model calls.
# Reports median and individual samples in milliseconds. The first sample
# includes cold work; subsequent samples revisit the same scroll windows.
# Event/frame timings include native drawing, not terminal-emulator latency.
alias Alto.TUI.{Cache, Transcript, App, State, View}
alias ExRatatui.CellSession
alias ExRatatui.Event.Mouse

measure = fn name, fun ->
  times =
    for _ <- 1..5 do
      {us, _} = :timer.tc(fun)
      us / 1000
    end

  IO.inspect({name, Enum.sort(times) |> Enum.at(2), times})
end

source = "```elixir\n" <> Enum.map_join(1..600, "\n", &"  IO.puts(\"line #{&1} 猫\")") <> "\n```"

entries =
  for n <- 1..100,
      do: %{
        kind: :assistant,
        text:
          "## Answer #{n}\n\n" <>
            String.duplicate("Some **useful** information. ", 20) <> "\n\n```elixir\n:ok\n```"
      }

Cache.clear()
measure.("100 entries static index", fn -> Transcript.index(entries, 84) end)

measure.("100 entries changed tail index", fn ->
  Transcript.index(entries ++ [%{kind: :assistant, text: "new #{System.unique_integer()}"}], 84)
end)

Cache.clear()
plan = Transcript.index([%{kind: :assistant, text: source}], 84)

measure.("600 line code scrolling", fn ->
  for offset <- 250..260, do: Transcript.window(plan, offset, 40)
end)

Cache.clear()

state = %State{
  textarea: ExRatatui.textarea_new(),
  run_options: [],
  catalog_opts: [],
  dimensions: {180, 50},
  transcript_follow?: false
}

state = State.put_entries(state, nil, entries)
terminal = CellSession.new(180, 50)
rect = View.layout(state, 180, 50).transcript
mouse = %Mouse{kind: "scroll_down", x: rect.x + 2, y: rect.y + 2}
paint = fn state -> CellSession.draw(terminal, App.render(state, %{width: 180, height: 50})) end
paint.(state)

measure.("20 scroll events and frames", fn ->
  Enum.reduce(1..20, state, fn _, state ->
    {:noreply, state} = App.handle_event(mouse, state)
    paint.(state)
    state
  end)
end)

CellSession.close(terminal)
