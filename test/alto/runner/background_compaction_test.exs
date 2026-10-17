defmodule Alto.Runner.BackgroundCompactionTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Transcript
  alias Alto.Runner.Execution.{Compactor, Setup}
  alias Alto.Runner.Execution.Transcript, as: RunTranscript

  defmodule Reducer do
    @behaviour Alto.Context.Reducer

    def compact(input, model, opts) do
      send(opts[:owner], {:reducer, self(), input})

      receive do
        :release ->
          {:ok, %{content: "Earlier work summarized.", data: %{}}}

        :fail ->
          {:error, :cannot_reduce}

        :crash ->
          exit(:reducer_crash)

        {:model_then, terminal} ->
          {:ok, completion} = model.(%{messages: [%{"role" => "user", "content" => "reduce"}]})
          send(opts[:owner], {:model_done, model})

          case terminal do
            :success -> {:ok, %{content: completion.message, data: %{}}}
            :crash -> exit(:after_model)
            _ -> receive do: (:never -> :ok)
          end

        :model ->
          with {:ok, completion} <-
                 model.(%{messages: [%{"role" => "user", "content" => "reduce"}]}) do
            {:ok, %{content: completion.message, data: %{}}}
          end
      end
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(opts), do: %{context_window: opts[:window] || 2_000}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:request, self(), request})

      tokens =
        if request.messages == [%{"role" => "user", "content" => "reduce"}],
          do: opts[:reduction_tokens] || 100,
          else: 100

      receive do
        {:complete, message, calls} ->
          {:ok,
           %{
             message: message,
             tool_calls: calls,
             usage: %{input_tokens: tokens, output_tokens: 10}
           }}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-background-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    history = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => "initial requirement"},
      %{"role" => "assistant", "content" => String.duplicate("history", 150)}
    ]

    opts = [
      session: :new,
      session_dir: dir,
      provider: {Provider, owner: self()},
      tools: [Alto.TestSupport.EchoTool],
      resume: %{"messages" => history, "transcript_bytes" => Transcript.bytes(history)},
      loop: Alto.default_loop(context: Alto.Context.Window.new(compact_at: 0.5)),
      compaction: [
        strategy: {Reducer, owner: self()},
        mode: :background,
        keep_initial_messages: 1,
        keep_recent_messages: 1,
        max_compactions: 2
      ]
    ]

    %{opts: opts}
  end

  test "soft pressure lets model and tool turns proceed with only one pending reducer", %{
    opts: opts
  } do
    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    assert_receive {:request, first, request}, 2_000
    assert Enum.any?(request.messages, &(&1["content"] == String.duplicate("history", 150)))

    send(first, {:complete, nil, [call("one")]})
    assert_receive {:request, second, request}, 2_000
    assert Enum.any?(request.messages, &(&1["tool_call_id"] == "one"))
    refute_received {:reducer, _, _}
    monitor = Process.monitor(reducer)

    # Finishing a run must not wait for an unneeded background result.
    send(second, {:complete, "done", []})
    assert %{status: :ok, output: "done", model_requests: 2} = Alto.await(handle)
    assert_receive {:DOWN, ^monitor, :process, ^reducer, _}, 2_000
  end

  test "a completed snapshot preserves all appended tool groups and steering verbatim", %{
    opts: opts
  } do
    with_run(opts, fn run ->
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, reducer, input}, 2_000
      assert [%{"content" => "initial requirement"} | _] = tl(input.pinned)

      tail = [
        %{"role" => "assistant", "content" => nil, "tool_calls" => [wire_call("late")]},
        %{"role" => "tool", "tool_call_id" => "late", "content" => "late result"},
        %{"role" => "user", "content" => "New correction: keep this exactly."}
      ]

      current =
        Enum.reduce(tail, run, fn message, run ->
          {:ok, run} = RunTranscript.append(run, message)
          run
        end)

      # Polling is nonblocking while the reducer is held at its barrier.
      assert RunTranscript.poll(current).messages_rev == current.messages_rev
      send(reducer, :release)
      assert {:ok, reduced} = RunTranscript.reduce(current)
      messages = Enum.reverse(reduced.messages_rev)
      assert Enum.take(messages, -length(tail)) == tail
      assert Enum.take(messages, 2) == input.pinned
      assert reduced.compaction_count == 1
      assert reduced.transcript_bytes < current.transcript_bytes
      assert :ok = Transcript.validate(messages)

      assert Enum.count(
               Alto.EventBuffer.to_list(reduced.event_buffer),
               &(&1.type == :context_compacted)
             ) == 1
    end)
  end

  test "hard model limit waits for the existing snapshot and never dispatches oversized input", %{
    opts: opts
  } do
    opts = Keyword.put(opts, :provider, {Provider, owner: self(), window: 1_650})
    opts = Keyword.update!(opts, :compaction, &Keyword.put(&1, :max_compactions, 1))
    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    assert_receive {:request, first, _}, 2_000
    send(first, {:complete, nil, [call("one", String.duplicate("x", 300))]})
    refute_receive {:request, _, _}, 50
    send(reducer, :release)
    assert_receive {:request, second, request}, 2_000
    assert :ok = Transcript.validate(request.messages)
    assert Enum.any?(request.messages, &(&1["tool_call_id"] == "one"))
    send(second, {:complete, "done", []})
    assert %{status: :ok} = result = Alto.await(handle)
    assert Enum.count(result.events, &(&1.type == :context_compacted)) == 1
    refute_received {:reducer, _, _}
  end

  test "transcript overflow joins the pending snapshot before appending", %{opts: opts} do
    with_run(opts, fn run ->
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, reducer, _}, 2_000
      run = %{run | max_transcript_bytes: run.transcript_bytes + 20}
      message = %{"role" => "user", "content" => String.duplicate("tail", 40)}
      send(reducer, :release)
      assert {:ok, reduced} = RunTranscript.append(run, message)
      assert hd(reduced.messages_rev) == message
      assert reduced.compaction_count == 1
      assert reduced.transcript_bytes <= run.max_transcript_bytes
    end)
  end

  test "a changed prefix rejects a stale result without losing current messages", %{opts: opts} do
    with_run(opts, fn run ->
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, reducer, _}, 2_000
      changed = [%{"role" => "user", "content" => "entirely replaced"}]
      current = %{run | messages_rev: changed, transcript_bytes: Transcript.bytes(changed)}
      send(reducer, :release)
      assert {:error, :compaction_snapshot_changed, same} = RunTranscript.reduce(current)
      assert same.messages_rev == changed
      assert same.compaction_count == 0
    end)
  end

  test "poll installs a ready result without waiting and persists the exact tail", %{opts: opts} do
    opts = Keyword.put(opts, :session_history, :settled)

    with_run(opts, fn run ->
      {:ok, run} = Alto.Runner.Execution.History.persist(run)
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, reducer, _}, 2_000
      {:ok, run} = RunTranscript.append(run, %{"role" => "user", "content" => "late steering"})
      task = :sys.get_state(run.compactor).job.task
      ref = Process.monitor(task.pid)
      send(reducer, :release)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      # The task sends its result before exiting. Synchronize with its owner
      # after observing that exit so poll exercises the ready-result path.
      await_ready(run.compactor)
      reduced = RunTranscript.poll(run)
      assert reduced.compaction_count == 1
      assert hd(reduced.messages_rev)["content"] == "late steering"
      assert RunTranscript.poll(reduced).compaction_count == 1
      {:ok, saved} = Alto.Runner.Execution.History.persist(reduced)

      assert {:ok, snapshot} =
               Alto.Session.transcript(saved.session, session_dir: saved.session_dir)

      assert snapshot["messages"] == Enum.reverse(saved.messages_rev)
    end)
  end

  test "a reducer timeout leaves the transcript intact and terminates its worker", %{opts: opts} do
    with_run(Keyword.put(opts, :provider_timeout, 100), fn run ->
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, reducer, _}, 2_000
      ref = Process.monitor(reducer)
      assert {:error, {:participant_failed, :timeout}, same} = RunTranscript.reduce(run)
      assert same.messages_rev == run.messages_rev
      assert same.compaction_count == 0
      assert_receive {:DOWN, ^ref, :process, ^reducer, _}, 2_000
    end)
  end

  test "cancelled attempts cannot dispatch again or reuse an artifact identity", %{opts: opts} do
    with_run(opts, fn run ->
      run = RunTranscript.start_background(run)
      assert_receive {:reducer, first, first_input}, 2_000
      ref = Process.monitor(first)
      run = RunTranscript.finish(run)
      assert_receive {:DOWN, ^ref, :process, ^first, _}, 2_000

      assert {:error, :reduction_model_closed} =
               Compactor.reserve_model(Map.put(run, :compaction_model, true))

      run = RunTranscript.start_background(run)
      assert_receive {:reducer, second, second_input}, 2_000
      assert first_input.artifact_id != second_input.artifact_id
      assert first_input.count == second_input.count
      send(second, :release)
      assert {:ok, _} = RunTranscript.reduce(run)
    end)
  end

  test "approval checkpoints cancel background work and restore without worker identities", %{
    opts: opts
  } do
    opts =
      Keyword.merge(opts,
        tools: [Alto.TestSupport.GuardedEchoTool],
        approval: :suspend,
        checkpoint_version: "background-v1"
      )

    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    assert_receive {:request, foreground, _}, 2_000
    ref = Process.monitor(reducer)
    send(foreground, {:complete, nil, [call("approval")]})
    assert %{status: :suspended, checkpoint: packet} = paused = Alto.await(handle)
    assert_receive {:DOWN, ^ref, :process, ^reducer, _}, 2_000
    assert {:ok, decoded} = Alto.Runner.Checkpoint.decode(packet["state"])
    refute Map.has_key?(decoded.run, :compactor)
    assert decoded.run.model_requests == paused.model_requests

    {:ok, resumed} = Alto.start("current", Keyword.put(opts, :checkpoint, {packet, :approve}))
    assert_receive {:reducer, new_reducer, _}, 2_000
    assert new_reducer != reducer
    assert_receive {:request, after_approval, request}, 2_000
    assert Enum.any?(request.messages, &(&1["tool_call_id"] == "approval"))
    send(after_approval, {:complete, "restored", []})
    assert %{status: :ok, output: "restored", model_requests: 2} = Alto.await(resumed)
  end

  @tag capture_log: true
  test "reducer failure and crash leave history intact", %{opts: opts} do
    for command <- [:fail, :crash] do
      with_run(opts, fn run ->
        run = RunTranscript.start_background(run)
        assert_receive {:reducer, reducer, _}, 2_000
        send(reducer, command)
        assert {:error, _, same} = RunTranscript.reduce(run)
        assert same.messages_rev == run.messages_rev
        assert same.compaction_count == 0
      end)
    end
  end

  test "cancellation stops both the foreground request and pending reducer", %{opts: opts} do
    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    assert_receive {:request, foreground, _}, 2_000
    reducer_ref = Process.monitor(reducer)
    foreground_ref = Process.monitor(foreground)
    assert :ok = Alto.cancel(handle, :stop)
    assert %{status: :cancelled, reason: :stop} = Alto.await(handle)
    assert_receive {:DOWN, ^reducer_ref, :process, ^reducer, _}, 2_000
    assert_receive {:DOWN, ^foreground_ref, :process, ^foreground, _}, 2_000
  end

  test "background model usage merges without overwriting foreground accounting", %{opts: opts} do
    opts = Keyword.put(opts, :provider, {Provider, owner: self(), reduction_tokens: 20})
    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    assert_receive {:request, foreground, _}, 2_000
    send(reducer, :model)
    assert_receive {:request, reduction, %{messages: [%{"content" => "reduce"}]}}, 2_000
    ref = Process.monitor(reducer)
    send(reduction, {:complete, "summary", []})
    assert_receive {:DOWN, ^ref, :process, ^reducer, :normal}, 2_000
    send(foreground, {:complete, "done", []})
    assert %{status: :ok, model_requests: 2, usage: usage} = Alto.await(handle)
    assert usage.input_tokens == 120
    assert usage.last_input_tokens == 100
    assert usage.output_tokens == 20
    assert usage.requests == 2
  end

  test "local step and global request limits are shared across concurrent model calls", %{
    opts: opts
  } do
    for limit <- [:max_steps, :max_model_requests] do
      {:ok, handle} = Alto.start("current", Keyword.put(opts, limit, 1))
      assert_receive {:reducer, reducer, _}, 2_000
      assert_receive {:request, foreground, _}, 2_000
      ref = Process.monitor(reducer)
      send(reducer, :model)
      assert_receive {:DOWN, ^ref, :process, ^reducer, :normal}, 2_000
      refute_received {:request, _, %{messages: [%{"content" => "reduce"}]}}
      send(foreground, {:complete, "done", []})
      assert %{status: :ok} = result = Alto.await(handle)
      assert result.usage.requests == 1
      assert result.model_requests == if(limit == :max_steps, do: 1, else: 2)
    end
  end

  @tag capture_log: true
  test "both reduction modes retain accounting after completion, crash, timeout and cancellation",
       %{opts: opts} do
    for mode <- [:blocking, :background], terminal <- [:success, :crash, :timeout, :cancel] do
      cancel_ref = make_ref()

      options =
        opts
        |> Keyword.update!(:compaction, &Keyword.put(&1, :mode, mode))
        |> Keyword.merge(
          cancel_ref: cancel_ref,
          provider_timeout: if(terminal == :timeout, do: 500, else: 5_000)
        )

      task =
        Task.async(fn ->
          with_run(options, fn run ->
            run = RunTranscript.start_background(run)
            result = RunTranscript.reduce(run)

            next =
              case result do
                {:ok, next} ->
                  assert terminal == :success
                  assert next.compaction_count == 1
                  next

                {:error, reason, next} ->
                  assert terminal != :success
                  if terminal == :cancel, do: assert(reason == {:cancelled, :operator})
                  assert next.messages_rev == run.messages_rev
                  assert next.compaction_count == 0
                  next
              end

            assert RunTranscript.finish(next) == next
            next
          end)
        end)

      assert_receive {:reducer, reducer, _}, 2_000
      monitor = Process.monitor(reducer)
      send(reducer, {:model_then, terminal})
      assert_receive {:request, provider, _}, 2_000
      send(provider, {:complete, "summary", []})
      assert_receive {:model_done, callback}, 2_000
      if terminal == :cancel, do: send(task.pid, {:alto_cancel, cancel_ref, :operator})
      next = Task.await(task, 2_000)
      assert next.model_requests == 1
      assert next.usage.input_tokens == 100
      assert next.usage.output_tokens == 10
      assert next.usage.requests == 1
      assert [%{usage: %{input_tokens: 100}}] = next.provider_attempts
      assert_receive {:DOWN, ^monitor, :process, ^reducer, _}, 2_000
      assert {:error, :reduction_model_closed} = callback.(%{messages: []})
      refute_received {:request, _, _}
    end
  end

  test "default blocking mode waits for reduction before dispatching foreground work", %{
    opts: opts
  } do
    opts = Keyword.update!(opts, :compaction, &Keyword.delete(&1, :mode))
    {:ok, handle} = Alto.start("current", opts)
    assert_receive {:reducer, reducer, _}, 2_000
    refute_receive {:request, _, _}, 50
    send(reducer, :release)
    assert_receive {:request, foreground, request}, 2_000
    assert Enum.any?(request.messages, &(&1["content"] == "Earlier work summarized."))
    send(foreground, {:complete, "done", []})
    assert %{status: :ok, output: "done"} = Alto.await(handle)
  end

  defp with_run(opts, fun) do
    opts = Keyword.put(opts, :session, Alto.Session.generate_id())

    Compactor.scope(opts, fn opts ->
      {:ok, run} = Setup.open("current", opts)
      fun.(run)
    end)
  end

  defp await_ready(compactor, attempts \\ 100) do
    assert attempts > 0

    if :sys.get_state(compactor).job.result == :pending do
      Process.sleep(1)
      await_ready(compactor, attempts - 1)
    end
  end

  defp call(id, value \\ "hello"),
    do: %{id: id, name: "echo", arguments_json: JSON.encode!(%{value: value})}

  defp wire_call(id),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => "echo", "arguments" => "{}"}
    }
end
