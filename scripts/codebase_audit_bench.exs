# Offline synthetic audit probes. Run core from the root and tui from packages/alto_tui:
# mix run --no-compile scripts/codebase_audit_bench.exs core
# mix run --no-compile ../../scripts/codebase_audit_bench.exs tui
# No user sessions, provider requests, catalog changes, or production mutations.
defmodule AltoAuditProbe do
  @compile {:no_warn_undefined,
            [
              Alto.TUI.Cache,
              Alto.TUI.Markdown,
              Alto.TUI.Transcript,
              Alto.TUI.Backends.Codex,
              Alto.TUI.State
            ]}
  def sample(label, fun, repeats \\ 5) do
    samples =
      for _ <- 1..repeats do
        Task.async(fn ->
          {us, value} = :timer.tc(fun)
          %{ms: us / 1000, value: value}
        end)
        |> Task.await(120_000)
      end

    times = Enum.sort(Enum.map(samples, & &1.ms))
    emit(%{probe: label, median_ms: Enum.at(times, div(repeats, 2)), samples: samples})
  end

  def emit(value), do: IO.puts(JSON.encode!(value))

  def core do
    alias Alto.Providers.Anthropic.Stream, as: Anthropic
    sink = fn _ -> :ok end

    start =
      JSON.encode!(%{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      })

    delta =
      JSON.encode!(%{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: String.duplicate("x", 64)}
      })

    initial = Anthropic.consume(Anthropic.new(), start, sink)

    for count <- [1000, 4000, 8000] do
      sample("anthropic_64_byte_chunks_#{count}", fn ->
        result =
          Enum.reduce(1..count, initial, fn _, acc -> Anthropic.consume(acc, delta, sink) end)

        byte_size(result.blocks[0]["text"])
      end)
    end

    for count <- [250, 500, 1000] do
      before = Enum.map_join(1..count, "\n", &"before #{&1}")
      after_text = Enum.map_join(1..count, "\n", &"after #{&1}")

      sample(
        "diff_unrelated_lines_#{count}_128_byte_preview",
        fn ->
          result = Alto.Tools.UnifiedDiff.render("synthetic", before, after_text, 128)
          %{bytes: byte_size(result.content), truncated: result.truncated}
        end,
        3
      )
    end

    dir = Path.join(System.tmp_dir!(), "alto-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      path = Path.join(dir, "source.txt")
      File.write!(path, String.duplicate("needle ", 20) <> "\n" <> String.duplicate("x", 999_000))

      {:ok, read} =
        Alto.Tools.ReadFile.run(
          %{
            "path" => "source.txt",
            "start_line" => 1,
            "line_count" => 1,
            "offset" => 0,
            "limit" => 47_000
          },
          %{cwd: dir},
          Alto.Tools.ReadFile.options()
        )

      {:ok, search} =
        Alto.Tools.SearchFiles.run(
          %{"path" => "source.txt", "query" => "needle", "case_sensitive" => true},
          %{cwd: dir},
          Alto.Tools.SearchFiles.options()
        )

      emit(%{
        probe: "file_result_backing_bytes",
        read_bytes: byte_size(read.content),
        read_backing: :binary.referenced_byte_size(read.content),
        search_bytes: byte_size(hd(search.matches).text),
        search_backing: :binary.referenced_byte_size(hd(search.matches).text)
      })

      for bytes <- [1_000_000, 4_000_000, 8_000_000] do
        path = Path.join(dir, "long.jsonl")
        File.write!(path, String.duplicate("x", bytes) <> "\n")

        sample("log_scan_single_line_#{bytes}", fn ->
          {:ok, size, _, _} =
            Alto.Session.LogScan.fold(path, 16_000_000, 0, "", 0, 0, fn line, n ->
              {:ok, n + byte_size(line)}
            end)

          size
        end)
      end
    after
      File.rm_rf!(dir)
    end

    owner = self()

    queue =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:settle, _, :ack, []}} ->
            send(owner, :queue_entered)
            Process.sleep(250)
            GenServer.reply(from, :ok)
        end
      end)

    {:ok, registry} =
      Alto.FrontEnd.Registry.start_link(
        name: nil,
        queue: queue,
        config_resolver: fn _ -> {:ok, []} end
      )

    pending =
      Task.async(fn -> Alto.FrontEnd.Registry.request(registry, {:queue_ack, "synthetic"}) end)

    receive do: (:queue_entered -> :ok)
    {us, []} = :timer.tc(fn -> Alto.FrontEnd.Registry.request(registry, :run_ids) end)
    emit(%{probe: "registry_unrelated_query_behind_250ms_queue", ms: us / 1000})
    :ok = Task.await(pending)
    GenServer.stop(registry)

    before = DynamicSupervisor.count_children(Alto.AgentSupervisor).active
    specs = for n <- 1..8, do: %{id: "child-#{n}"}

    {:ok, outcomes} =
      Alto.Runner.Agents.batch(
        specs,
        4,
        fn _ ->
          {:ok, host} = Alto.Runner.TaskHost.start(fn _ -> Alto.Runner.Result.empty() end, [])
          {:ok, %Alto.Runner.Handle{runner: Alto.Runner.Serial, state: host}}
        end,
        fn -> :continue end
      )

    emit(%{
      probe: "completed_child_hosts",
      outcomes: length(outcomes),
      before: before,
      after_batch: DynamicSupervisor.count_children(Alto.AgentSupervisor).active
    })
  end

  def tui do
    # Warm the NIF and syntax tables before collecting samples.
    Alto.TUI.Markdown.tail("warm", 84, 40)

    for size <- [4000, 16_000, 64_000] do
      source = String.duplicate("word ", div(size, 5))

      sample("markdown_tail_single_block_#{size}", fn ->
        Alto.TUI.Cache.clear()
        length(Alto.TUI.Markdown.tail(source, 84, 40).lines)
      end)

      sample("markdown_index_and_window_single_block_#{size}", fn ->
        Alto.TUI.Cache.clear()
        layout = Alto.TUI.Markdown.layout(source, 84)
        length(Alto.TUI.Markdown.window(layout, max(layout.rows - 40, 0), 40))
      end)
    end

    for budget <- [16_000_000, 64_000_000] do
      sample("viewport_20000_rows_40_visible_budget_#{budget}", fn ->
        Alto.TUI.Cache.configure(budget)

        entries =
          for n <- 1..200, do: %{kind: :user, text: "#{n}\n" <> String.duplicate("row\n", 98)}

        index = Alto.TUI.Transcript.index(entries, 84)

        cached =
          Enum.any?(Alto.TUI.Cache.stats().items, fn {{namespace, _}, _} ->
            namespace == {Alto.TUI.Transcript, :indexes}
          end)

        offset = max(index.rows - 80, 0)
        {window_us, window} = :timer.tc(fn -> Alto.TUI.Transcript.window(index, offset, 40) end)

        {viewport_us, text} =
          :timer.tc(fn -> Alto.TUI.Transcript.viewport(entries, 84, offset, 40) end)

        %{
          rows: index.rows,
          index_cached: cached,
          index_external_bytes: :erlang.external_size(index),
          visible: length(window),
          padded: length(text.lines),
          window_ms: window_us / 1000,
          viewport_ms: viewport_us / 1000,
          window_external_bytes: :erlang.external_size(window),
          padded_external_bytes: :erlang.external_size(text)
        }
      end)
    end

    backend = Alto.TUI.Backends.Codex

    state =
      struct!(Alto.TUI.State,
        textarea: nil,
        run_options: [],
        catalog_opts: [],
        selected_task_id: "task",
        backend_state: %{backend => %{client: self(), pending_messages: []}},
        runs: %{
          "run" => %{
            local_id: "run",
            kind: :codex,
            task_id: "task",
            thread_id: "thread",
            turn_id: "turn"
          }
        }
      )

    params = %{
      "threadId" => "thread",
      "turnId" => "turn",
      "itemId" => "item",
      "delta" => "short summary"
    }

    {:noreply, state} =
      backend.ui(
        {:message, {:codex_notification, self(), "item/reasoning/summaryTextDelta", params}},
        state,
        []
      )

    raw = %{params | "delta" => String.duplicate("x", 100_000)}

    Enum.reduce(1..20, state, fn n, acc ->
      {:noreply, next} =
        backend.ui(
          {:message, {:codex_notification, self(), "item/reasoning/textDelta", raw}},
          acc,
          []
        )

      if n in [10, 19, 20] do
        entries = Map.get(next.entries, "task", [])

        emit(%{
          probe: "codex_hidden_raw_reasoning",
          raw_bytes_sent: n * 100_000,
          entries: length(entries),
          retained_entry_bytes: :erlang.external_size(entries),
          shown_text_bytes: Enum.reduce(entries, 0, &(byte_size(&1.text) + &2))
        })
      end

      next
    end)
  end
end

case System.argv() do
  ["core"] -> AltoAuditProbe.core()
  ["tui"] -> AltoAuditProbe.tui()
  _ -> raise "Expected core or tui"
end

