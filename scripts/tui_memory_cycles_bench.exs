# Run from packages/alto_tui with mix run --no-compile ../../scripts/tui_memory_cycles_bench.exs LABEL
# Synthetic repeated working sets; no sessions, providers or user data.
defmodule AltoMemoryCyclesBench do
  alias Alto.TUI.{Cache, Markdown, State, Transcript}

  def snapshot do
    status = File.read!("/proc/self/status")
    smaps = File.read!("/proc/self/smaps_rollup")

    field = fn text, name ->
      [_, value] = Regex.run(~r/^#{name}:\s+(\d+)/m, text)
      String.to_integer(value) * 1024
    end

    %{
      rss: field.(status, "VmRSS"),
      peak_rss: field.(status, "VmHWM"),
      pss: field.(smaps, "Pss"),
      anonymous: field.(smaps, "Anonymous"),
      beam: :erlang.memory(:total),
      binary: :erlang.memory(:binary),
      process: Process.info(self(), :memory) |> elem(1),
      cache_weight: Cache.stats().bytes
    }
  end

  def run do
    Markdown.render("```elixir\nIO.puts(:ok)\n```", 84)
    initial = snapshot()
    long? = Enum.at(System.argv(), 1) == "long"
    width = if long?, do: 41, else: 84
    count = if long?, do: 40, else: 120
    repetitions = if long?, do: 110, else: 45

    results =
      for cycle <- 1..3 do
        {elapsed, {state, samples}} =
          :timer.tc(fn ->
            Enum.reduce(
              1..12,
              {%State{textarea: ExRatatui.textarea_new(), run_options: [], catalog_opts: []}, []},
              fn n, {state, times} ->
                id = "task-#{n}"

                entries =
                  for i <- 1..count do
                    %{
                      kind: :assistant,
                      text:
                        "## Conversation #{n}, entry #{i}\n\n" <>
                          String.duplicate(
                            "Evidence #{n}/#{i} **strong** and `inline code` with wrapped text. ",
                            repetitions
                          )
                    }
                  end

                Cache.owner(id)
                state = State.put_entries(%{state | selected_task_id: id}, id, entries)

                {micros, _} =
                  :timer.tc(fn ->
                    index = Transcript.index(entries, width)
                    Transcript.window(index, max(index.rows - 40, 0), 40)
                    Transcript.tail(entries, width, 40)
                  end)

                {state, [micros | times]}
              end
            )
          end)

        Process.put(:working_set, state)
        :erlang.garbage_collect()

        Map.merge(snapshot(), %{
          cycle: cycle,
          elapsed_us: elapsed,
          index_us: Enum.reverse(samples)
        })
      end

    Process.delete(:working_set)
    Cache.clear()
    :erlang.garbage_collect()

    IO.puts(
      JSON.encode!(%{
        label: List.first(System.argv()),
        initial: initial,
        cycles: results,
        released: snapshot()
      })
    )
  end
end

AltoMemoryCyclesBench.run()
