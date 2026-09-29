# Core: mix run scripts/rss_bench.exs core
# TUI: cd packages/alto_tui && mix run ../../scripts/rss_bench.exs tui
# Synthetic/offline workloads. Linux RSS includes native and allocator memory.
defmodule AltoRSSBench do
  def mib(bytes), do: Float.round(bytes / 1_048_576, 2)

  def snapshot(label, pid) do
    vm = :erlang.memory()
    os = File.read!("/proc/self/status")

    field = fn name ->
      [_, value] = Regex.run(~r/^#{name}:\s+(\d+)/m, os)
      mib(String.to_integer(value) * 1024)
    end

    info = Process.info(pid, [:memory, :message_queue_len, :binary]) || []

    IO.puts(
      JSON.encode!(%{
        stage: label,
        rss_mib: field.("VmRSS"),
        peak_rss_mib: field.("VmHWM"),
        beam_mib: mib(vm[:total]),
        processes_mib: mib(vm[:processes]),
        binary_mib: mib(vm[:binary]),
        ets_mib: mib(vm[:ets]),
        worker_mib: mib(info[:memory] || 0),
        worker_binary_refs: length(info[:binary] || []),
        mailbox: info[:message_queue_len]
      })
    )
  end

  def worker do
    receive do
      {:step, from, fun} ->
        result = fun.()
        send(from, {:done, result})
        worker()

      {:dict, from} ->
        rows =
          Process.get()
          |> Enum.map(fn {key, value} ->
            %{
              key: inspect(key),
              heap_mib: mib(:erts_debug.size(value) * :erlang.system_info(:wordsize))
            }
          end)
          |> Enum.sort_by(& &1.heap_mib, :desc)
          |> Enum.take(12)

        send(from, {:done, rows})
        worker()
    end
  end

  def step(pid, label, fun) do
    send(pid, {:step, self(), fun})

    receive do
      {:done, _} -> :ok
    after
      60_000 -> raise "step timeout: #{label}"
    end

    snapshot(label <> " before GC", pid)
    :erlang.garbage_collect(pid)
    snapshot(label <> " after GC", pid)
  end

  def entries(id) do
    for n <- 1..120 do
      %{
        kind: :assistant,
        text:
          "## Conversation #{id}, entry #{n}\n\n" <>
            String.duplicate(
              "Evidence #{id}/#{n} **strong** and `inline code` with wrapped text. ",
              45
            )
      }
    end
  end

  def run(mode) do
    IO.puts(
      JSON.encode!(%{
        runtime: System.version(),
        otp: to_string(:erlang.system_info(:otp_release)),
        schedulers: :erlang.system_info(:schedulers),
        online: :erlang.system_info(:schedulers_online),
        dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers),
        mode: mode
      })
    )

    pid = spawn_link(&worker/0)
    snapshot("boot", pid)

    case mode do
      "core" ->
        step(pid, "1000 unique 64KB tool events", fn ->
          buffer =
            Enum.reduce(1..1000, struct(Alto.EventBuffer), fn n, buffer ->
              payload = :binary.copy(<<rem(n, 251)>>, 64_000) <> Integer.to_string(n)

              {next, _} =
                Alto.EventBuffer.push(
                  buffer,
                  Alto.Event.durable(:tool_completed, %{value: %{output: payload}}),
                  1000
                )

              next
            end)

          Process.put(:retained, buffer)
          :ok
        end)

      "headers" ->
        step(pid, "200 cached session headers", fn ->
          dir =
            Path.join(System.tmp_dir!(), "alto-rss-headers-#{System.unique_integer([:positive])}")

          File.mkdir_p!(dir)

          try do
            headers =
              for n <- 1..200 do
                path = Path.join(dir, "header-#{n}.jsonl")

                header =
                  Alto.Session.started_record(%{
                    task: String.duplicate("task ", 24),
                    subagent: true
                  })

                File.write!(path, JSON.encode!(header) <> "\n" <> String.duplicate(" ", 40_000))
                Alto.Session.Children.header(path)
              end

            first = hd(headers)["task"]

            IO.puts(
              JSON.encode!(%{
                header_task_bytes: byte_size(first),
                backing_bytes: :binary.referenced_byte_size(first)
              })
            )

            Process.put(:retained, headers)
          after
            File.rm_rf!(dir)
          end

          :ok
        end)

      "hydration" ->
        step(pid, "4MB saved transcript reduced to bounded display", fn ->
          dir = Path.join(System.tmp_dir!(), "alto-rss-#{System.unique_integer([:positive])}")
          opts = [session_dir: dir]

          try do
            {:ok, id} = Alto.Session.create("memory probe", %{}, opts)

            messages = [
              %{"role" => "user", "content" => String.duplicate("large ", 700_000)},
              %{"role" => "assistant", "content" => String.duplicate("small ", 30)}
            ]

            {:ok, _} =
              Alto.Session.persist_settled(
                id,
                messages,
                Alto.Context.Transcript.bytes(messages),
                opts
              )

            entries = Alto.TUI.State.load_session_entries(id, opts)
            Process.put(:retained, entries)

            IO.puts(
              JSON.encode!(%{
                display_strings:
                  Enum.map(entries, fn entry ->
                    %{
                      bytes: byte_size(entry.text),
                      backing_bytes: :binary.referenced_byte_size(entry.text)
                    }
                  end)
              })
            )
          after
            File.rm_rf!(dir)
          end

          :ok
        end)

        step(pid, "detach retained display strings", fn ->
          entries =
            Process.get(:retained)
            |> Enum.map(fn entry ->
              Map.new(entry, fn {key, value} ->
                {key, if(is_binary(value), do: :binary.copy(value), else: value)}
              end)
            end)

          Process.put(:retained, entries)

          IO.puts(
            JSON.encode!(%{
              detached_display_strings:
                Enum.map(entries, fn entry ->
                  %{
                    bytes: byte_size(entry.text),
                    backing_bytes: :binary.referenced_byte_size(entry.text)
                  }
                end)
            })
          )

          :ok
        end)

      "search" ->
        step(pid, "20000-byte transcript, 10000 search matches", fn ->
          entries = [%{kind: :assistant, text: String.duplicate("a ", 10_000)}]
          Process.put(:retained, entries)
          Alto.TUI.Search.find(entries, "a")
          :ok
        end)

      mode when mode in ["tui", "legacy"] ->
        step(pid, "native syntax warmup", fn ->
          Alto.TUI.Markdown.render("```elixir\nIO.puts(:ok)\n```", 84)
          :ok
        end)

        step(pid, "one conversation " <> mode, fn ->
          entries = entries(1)
          Process.put(:retained, entries)

          if mode == "legacy",
            do: Alto.TUI.Transcript.render(entries, 84),
            else:
              (
                index = Alto.TUI.Transcript.index(entries, 84)
                Alto.TUI.Transcript.window(index, max(index.rows - 40, 0), 40)
              )

          :ok
        end)

        if mode == "tui" do
          step(pid, "12 conversation state and layout working set", fn ->
            state =
              struct(Alto.TUI.State,
                textarea: ExRatatui.textarea_new(),
                run_options: [],
                catalog_opts: []
              )

            state =
              Enum.reduce(1..12, state, fn n, state ->
                id = "task-#{n}"
                entries = entries(n)
                next = Alto.TUI.State.put_entries(%{state | selected_task_id: id}, id, entries)
                index = Alto.TUI.Transcript.index(entries, 84)
                Alto.TUI.Transcript.window(index, max(index.rows - 40, 0), 40)
                Alto.TUI.Transcript.tail(entries, 84, 40)
                next
              end)

            Process.put(:retained, state)
            :ok
          end)

          step(pid, "clear UI state but keep render caches", fn ->
            Process.delete(:retained)
            :ok
          end)
        end
    end

    send(pid, {:dict, self()})

    receive do
      {:done, rows} -> IO.puts(JSON.encode!(%{dictionary_heap_only: rows}))
    end

    step(pid, "clear all process caches", fn ->
      for {key, _} <- Process.get(), do: Process.delete(key)
      :ok
    end)

    ref = Process.monitor(pid)
    # Explicit shutdown of the synthetic worker; unlink before kill.
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    :erlang.garbage_collect()
    snapshot("worker exited", pid)
  end
end

AltoRSSBench.run(List.first(System.argv()) || "core")
