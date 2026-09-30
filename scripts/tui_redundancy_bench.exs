# From packages/alto_tui: mix run ../../scripts/tui_redundancy_bench.exs
# Synthetic viewport representation sizes; serialized bytes are not RSS.
alias Alto.TUI.{Cache, Transcript}
Cache.clear()
entries = for n <- 1..200, do: %{kind: :user, text: "#{n}: " <> String.duplicate("text", 100)}
index = Transcript.index(entries, 4)
offset = div(index.rows, 2)
window = Transcript.window(index, offset, 40)
viewport = Transcript.viewport(entries, 4, offset, 40)

IO.puts(
  JSON.encode!(%{
    entries: length(entries),
    total_rows: index.rows,
    visible_rows: length(window),
    viewport_serialized_bytes: :erlang.external_size(viewport),
    visible_serialized_bytes: :erlang.external_size(ExRatatui.Text.new(window))
  })
)
