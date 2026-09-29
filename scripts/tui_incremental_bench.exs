# From packages/alto_tui: mix run ../../scripts/tui_incremental_bench.exs [sess-...]
# Uses synthetic streaming/log workloads. Optional session IDs only read saved
# transcripts. Synthetic logs and disposable projections live under /tmp.
alias Alto.TUI.State

for count <- [100, 1000, 2000] do
  state = %State{textarea: ExRatatui.textarea_new(), run_options: [], catalog_opts: []}

  entries =
    for n <- 1..count,
        do: %{kind: :tool, text: "read #{n}", detail: String.duplicate("output\n", 20)}

  state = State.put_entries(state, nil, entries)

  {us, _} =
    :timer.tc(fn ->
      Enum.reduce(1..1000, state, fn _, s -> State.append_assistant_delta(s, nil, "text ") end)
    end)

  IO.inspect(%{history_entries: count, streaming_deltas: 1000, state_update_total_ms: us / 1000})
end

for id <- System.argv() do
  {:ok, snapshot} = Alto.Session.conversation(id)
  entries = Alto.ToolDisplay.transcript(snapshot["messages"])
  {us, index} = :timer.tc(fn -> Alto.TUI.Transcript.index(entries, 84) end)
  {draw, _} = :timer.tc(fn -> Alto.TUI.Transcript.window(index, max(index.rows - 60, 0), 40) end)
  IO.inspect(%{session: id, index_ms: us / 1000, viewport_ms: draw / 1000, rows: index.rows})
end

dir = Path.join(System.tmp_dir!(), "alto-projection-bench-#{System.unique_integer([:positive])}")
opts = [session_dir: dir]

try do
  {:ok, id} = Alto.Session.create("benchmark", %{}, opts)

  record =
    Alto.Session.event_record(
      "run",
      Alto.Event.durable(:model_completed, %{
        usage: %{input_tokens: 100, output_tokens: 10},
        message: String.duplicate("text ", 40)
      })
    )

  for _ <- 1..2000, do: :ok = Alto.Session.append(id, record, opts)

  for label <- ["cold replay", "unchanged cached replay", "appended replay"] do
    if label == "appended replay", do: :ok = Alto.Session.append(id, record, opts)
    {us, {:ok, projection}} = :timer.tc(fn -> Alto.TUI.SavedSession.load(id, opts) end)
    IO.inspect(%{operation: label, ms: us / 1000, requests: projection.usage.requests})
  end
after
  File.rm_rf!(dir)
end
