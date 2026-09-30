defmodule Alto.TUI.HistoryTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.History
  alias Alto.TUI.State
  alias Alto.TUI.App

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-history-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [session_dir: dir]
    {:ok, session} = Alto.Session.create("saved", %{}, opts)

    {:ok, _} =
      Alto.Session.persist_settled(
        session,
        [%{"role" => "user", "content" => "saved request"}],
        13,
        opts
      )

    Code.ensure_loaded!(Alto.TUI.Backends.Native)

    task = %{
      "id" => "task-a",
      "project_id" => "project",
      "conversation_id" => session,
      "backend" => "alto"
    }

    state = %State{
      textarea: ExRatatui.textarea_new(),
      run_options: [tui_backends: [alto: {Alto.TUI.Backends.Native, []}]],
      catalog_opts: opts,
      selected_project_id: "project",
      selected_backend: :alto,
      tasks: %{"project" => [task]},
      async_history?: true
    }

    %{state: state, task: task}
  end

  test "selection returns before hydration and paints saved entries independently of discovery",
       %{state: state} do
    state = State.select_task(state, "task-a")
    assert state.selected_task_id == "task-a"
    refute Map.has_key?(state.entries, "task-a")
    assert %{token: token, monitor: monitor} = state.history_load
    assert_receive {:tui_history, ^token, :entries, entries}, 2000
    {:noreply, state, _} = App.handle_info({:tui_history, token, :entries, entries}, state)
    assert [%{text: "saved request"}] = State.visible_entries(state)
    assert_receive {:tui_history, ^token, :usage, usage}, 2000
    state = History.apply(state, token, :usage, usage)
    assert_receive {:tui_history, ^token, :subagents, agents}, 2000
    state = History.apply(state, token, :subagents, agents)
    assert_receive {:DOWN, ^monitor, :process, pid, :normal}, 2000
    {:noreply, state} = App.handle_info({:DOWN, monitor, :process, pid, :normal}, state)
    assert state.history_load == nil
    assert State.select_task(state, "task-a").history_load == nil
  end

  test "rapid switching cancels obsolete work and ignores queued results", %{
    state: state,
    task: task
  } do
    state = State.select_task(state, task["id"])
    %{token: token, pid: pid} = state.history_load
    next = State.new_task(state)
    assert next.history_load == nil
    assert History.apply(next, token, :entries, [%{kind: :user, text: "stale"}]) == next
    assert History.apply(next, token, :subagents, {%{"old" => %{}}, ["stale warning"]}) == next
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  test "input submitted during a cold load survives navigating away", %{state: state} do
    state = State.select_task(state, "task-a")
    token = state.history_load.token
    worker = state.history_load.pid
    monitor = Process.monitor(worker)
    ExRatatui.textarea_set_value(state.textarea, "continue after loading")
    {:noreply, queued} = App.handle_event(%ExRatatui.Event.Key{code: "enter"}, state)
    on_exit(fn -> Alto.Input.close(queued.inputs["task-a"]) end)
    assert State.input_pending?(queued, "task-a")
    assert ExRatatui.textarea_get_value(queued.textarea) == ""
    away = State.new_task(queued)
    assert away.history_load.token == token
    assert_receive {:tui_history, ^token, :usage, usage}, 2000
    {:noreply, away, _} = App.handle_info({:tui_history, token, :usage, usage}, away)
    assert_receive {:tui_history, ^token, :entries, entries}, 2000
    {:noreply, away, _} = App.handle_info({:tui_history, token, :entries, entries}, away)
    assert away.selected_task_id == nil
    assert away.history_load == nil
    assert [%{text: "saved request"}] = away.entries["task-a"]
    assert_receive {:alto_tui_send_input, "task-a"}
    # Hydration may publish input readiness before its final cache write finishes.
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2000
  end

  test "cache eviction keeps recently revisited tasks", %{state: state, task: task} do
    tasks =
      for n <- 1..13, do: task |> Map.put("id", "task-#{n}") |> Map.put("conversation_id", nil)

    state = %{state | tasks: %{"project" => tasks}, async_history?: false}

    state =
      Enum.reduce(1..12, state, fn n, acc ->
        State.put_entries(acc, "task-#{n}", [%{kind: :user, text: "#{n}"}])
      end)

    state = State.select_task(state, "task-1")
    state = State.put_entries(state, "task-13", [%{kind: :user, text: "13"}])
    assert Map.has_key?(state.entries, "task-1")
    assert Map.has_key?(state.entries, "task-13")
    refute Map.has_key?(state.entries, "task-2")
    assert map_size(state.entries) == 12
  end

  test "hydration preserves input and child events that arrive while reading", %{state: state} do
    token = make_ref()
    state = %{state | selected_task_id: "task-a", history_load: %{id: "task-a", token: token}}
    state = State.append_entry(state, "task-a", %{kind: :user, text: "continue"})
    state = History.apply(state, token, :entries, [%{kind: :assistant, text: "saved"}])
    assert Enum.map(State.visible_entries(state), & &1.text) == ["saved", "continue"]
    state = %{state | subagents: %{"task-a" => %{"child" => %{status: "running"}}}}
    state = History.apply(state, token, :subagents, {%{"child" => %{status: "unknown"}}, []})
    assert state.subagents["task-a"]["child"].status == "running"
  end

  test "bounded entries detach small text from oversized decoded sources", %{state: state} do
    large = String.duplicate("a", 4_000_000)
    small = binary_part(large, 0, 180)
    state = State.put_entries(state, nil, [%{kind: :assistant, text: small}])
    assert :binary.referenced_byte_size(hd(State.current_entries(state)).text) == 180
  end

  test "history byte pressure evicts inactive owners and their derived caches", %{state: state} do
    state = %{state | history_cache_bytes: 3000, selected_task_id: "a"}
    state = State.put_entries(state, "a", [%{kind: :user, text: String.duplicate("a", 1800)}])
    Alto.TUI.Cache.owner("a")
    Alto.TUI.Cache.fetch({__MODULE__, :view}, :old, 1, fn -> "old rendering" end)

    state =
      State.put_entries(%{state | selected_task_id: "b"}, "b", [
        %{kind: :user, text: String.duplicate("b", 1800)}
      ])

    refute Map.has_key?(state.entries, "a")
    assert Map.has_key?(state.entries, "b")
    assert Alto.TUI.Cache.stats().bytes == 0
  end
end
