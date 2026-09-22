defmodule Alto.TUI.AppTest do
  use ExUnit.Case, async: false

  alias Alto.TUI.{App, State, View}
  alias Alto.TUI.Backends.Codex
  alias ExRatatui.Event.{Key, Mouse}
  alias ExRatatui.Runtime

  defmodule Provider do
    @behaviour Alto.Provider

    def describe(opts), do: %{model: opts[:model], context_window: 100_000}

    def list_models(_opts),
      do: {:ok, [%{id: "test/model", name: "Test Model", context_length: 100_000}]}

    def stream(_request, sink, _opts) do
      sink.(Alto.Event.live(:model_delta, %{text: "Finished."}))

      {:ok,
       %{
         message: "Finished.",
         tool_calls: [],
         usage: %{
           "prompt_tokens" => 1_000,
           "completion_tokens" => 20,
           "prompt_tokens_details" => %{"cached_tokens" => 600}
         }
       }}
    end
  end

  defmodule FailingProvider do
    @behaviour Alto.Provider

    def describe(_opts), do: %{}

    def list_models(_opts),
      do: {:error, {:api_key_missing, %{authorization: "Bearer should-not-render"}}}

    def stream(_request, _sink, _opts), do: {:error, :not_used}
  end

  defmodule StopLoop do
    def init(_, _), do: Alto.Transition.stop(nil, :completed)
    def handle_event(_, _, _), do: Alto.Transition.stop(nil, :completed)
  end

  defmodule CustomBackend do
    @behaviour Alto.TUI.Backend
    def start(_task, prompt, options, opts) do
      send(opts[:owner], {:custom_start, Keyword.get(options, :approval)})
      Alto.start(prompt, Keyword.put(options, :loop, Alto.loop(StopLoop)))
    end

    def cancel(%{handle: handle}, reason, _opts), do: Alto.cancel(handle, reason)
  end

  defmodule ControllableCodexClient do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, %{owner: owner, login_from: nil}}

    @impl true
    def handle_call(
          {:request, "account/login/start", _params, _deadline},
          from,
          %{login_from: nil} = state
        ) do
      send(state.owner, {:codex_login_requested, self()})
      {:noreply, %{state | login_from: from}}
    end

    def handle_call({:request, "account/login/cancel", params, _deadline}, _from, state) do
      send(state.owner, {:codex_login_cancelled, params})
      {:reply, {:ok, %{}}, state}
    end

    @impl true
    def handle_info({:finish_login, result}, %{login_from: from} = state) when not is_nil(from) do
      GenServer.reply(from, result)
      {:noreply, %{state | login_from: nil}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-tui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "catalog.json")
    codex_server = Path.join(root, "codex_app_server.exs")

    File.write!(codex_server, """
    #!/usr/bin/env elixir
    Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
    |> Enum.reduce_while(%{logged_in: false, pending_turn: false}, fn
      :eof, _state -> {:halt, nil}
      {:error, _}, _state -> {:halt, nil}
      line, state ->
        message = JSON.decode!(line)
        id = message["id"]
        method = message["method"]

        state =
          cond do
            method == "initialize" ->
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{}}))
              state
            method == "initialized" -> state
            method == "account/read" ->
              account = if state.logged_in, do: %{"type" => "chatgpt", "email" => "pro@example.test", "planType" => "pro"}, else: nil
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"account" => account, "requiresOpenaiAuth" => true}}))
              state
            method == "account/login/start" ->
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"type" => "chatgpt", "loginId" => "login-1", "authUrl" => "https://chatgpt.test/oauth"}}))
              IO.puts(JSON.encode!(%{"method" => "account/login/completed", "params" => %{"loginId" => "login-1", "success" => true, "error" => nil}}))
              IO.puts(JSON.encode!(%{"method" => "account/updated", "params" => %{"authMode" => "chatgpt", "planType" => "pro"}}))
              %{state | logged_in: true}
            method == "model/list" ->
              model = %{"id" => "gpt-test", "model" => "gpt-test", "displayName" => "GPT Test", "description" => "", "isDefault" => true, "defaultReasoningEffort" => "medium", "supportedReasoningEfforts" => []}
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"data" => [model], "nextCursor" => nil}}))
              state
            method == "account/rateLimits/read" ->
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 22.0, "windowDurationMins" => 300, "resetsAt" => 1_900_000_000}}}}))
              state
            method == "thread/start" ->
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"thread" => %{"id" => "thr-tui"}}}))
              state
            method == "thread/resume" ->
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"thread" => %{"id" => message["params"]["threadId"]}}}))
              state
            method == "turn/start" ->
              IO.puts(JSON.encode!(%{"id" => "approval-evicted", "method" => "item/commandExecution/requestApproval", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "old-cmd", "command" => "old command", "cwd" => #{inspect(root)}}}))
              Enum.each(1..101, fn index ->
                IO.puts(JSON.encode!(%{"method" => "test/early", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "index" => index}}))
              end)
              IO.puts(JSON.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "msg", "delta" => "Working. "}}))
              IO.puts(JSON.encode!(%{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "tokenUsage" => %{"modelContextWindow" => 100_000, "last" => %{"inputTokens" => 1_000, "outputTokens" => 10, "cachedInputTokens" => 600, "reasoningOutputTokens" => 0, "totalTokens" => 1_010, "cacheWriteInputTokens" => 0}, "total" => %{"inputTokens" => 1_000, "outputTokens" => 10, "cachedInputTokens" => 600, "reasoningOutputTokens" => 0, "totalTokens" => 1_010, "cacheWriteInputTokens" => 0}}}}))
              IO.puts(JSON.encode!(%{"id" => "approval-1", "method" => "item/commandExecution/requestApproval", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "cmd", "command" => "mix test", "cwd" => #{inspect(root)}}}))
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"turn" => %{"id" => "turn-tui", "status" => "inProgress"}}}))
              %{state | pending_turn: true}
            id == "approval-evicted" and message["error"] ->
              File.write!(#{inspect(Path.join(root, "evicted-approval-rejected"))}, "rejected")
              state
            id == "approval-1" and state.pending_turn ->
              IO.puts(JSON.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "msg", "delta" => "Finished."}}))
              IO.puts(JSON.encode!(%{"method" => "turn/completed", "params" => %{"threadId" => "thr-tui", "turn" => %{"id" => "turn-tui", "status" => "completed", "items" => [], "error" => nil}}}))
              %{state | pending_turn: false}
            true ->
              if id, do: IO.puts(JSON.encode!(%{"id" => id, "result" => %{}}))
              state
          end

        {:cont, state}
    end)
    """)

    File.chmod!(codex_server, 0o755)

    config =
      Alto.Test.TUI.config(
        provider_profiles: [
          [
            id: "test",
            label: "Test Provider",
            provider: {Provider, model: "test/model"},
            models: [%{id: "test/model", name: "Test Model", context_length: 100_000}]
          ]
        ],
        loop: Alto.chat_loop(),
        tools: [],
        tui: [type_to_compose: true],
        sessions: true
      )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      catalog: catalog,
      credentials: Path.join(root, "credentials.json"),
      codex_server: codex_server,
      config: config
    }
  end

  test "Ctrl+G W opens a new folder workspace, preserves the draft and remembers the folder",
       context do
    folder = Path.join(context.root, "Second Project!")
    File.mkdir_p!(folder)

    state = state!(context, credentials_path: context.credentials)

    ExRatatui.textarea_insert_str(state.textarea, "draft survives")
    original = state.selected_project_id
    form = folder_form(state)
    assert form.overlay.kind == :workspace_form

    typed =
      Enum.reduce(String.graphemes("Second Project!"), form, fn code, state ->
        modifiers = if code in ["S", "P", "!"], do: ["shift"], else: []

        {:noreply, next} =
          App.handle_event(%Key{code: code, kind: "press", modifiers: modifiers}, state)

        next
      end)

    assert Alto.TUI.WorkspaceForm.path(typed.overlay) == "Second Project!"
    {:noreply, opened} = App.handle_event(%Key{code: "enter"}, typed)
    assert opened.overlay == nil
    assert opened.selected_project_id != original
    assert State.selected_project(opened)["root"] == folder
    assert opened.selected_task_id == nil
    assert opened.focus == :composer
    assert ExRatatui.textarea_get_value(opened.textarea) == "draft survives"
    {:ok, again} = State.open_workspace(opened, folder)
    assert again.selected_project_id == opened.selected_project_id
    assert length(again.projects) == 2

    restarted = state!(context, credentials_path: context.credentials)

    assert Enum.any?(restarted.projects, &(&1["root"] == folder))
  end

  test "create folder opens the typed nested path without losing the draft", context do
    state = state!(context)
    ExRatatui.textarea_insert_str(state.textarea, "keep this draft")
    form = folder_form(state)

    {:noreply, form} =
      App.handle_event(%ExRatatui.Event.Paste{content: "New Parent/Project É!"}, form)

    {:noreply, missing} = App.handle_event(%Key{code: "enter"}, form)
    folder = Path.join(context.root, "New Parent/Project É!")
    refute File.exists?(folder)
    assert missing.overlay.error =~ "Ctrl+N"
    {:noreply, opened} = App.handle_event(%Key{code: "n", modifiers: ["ctrl"]}, missing)
    assert File.dir?(folder)
    assert opened.overlay == nil
    assert State.selected_project(opened)["root"] == folder
    assert opened.selected_task_id == nil
    assert ExRatatui.textarea_get_value(opened.textarea) == "keep this draft"

    form = folder_form(opened)
    {:noreply, form} = App.handle_event(%ExRatatui.Event.Paste{content: folder}, form)
    {:noreply, failed} = App.handle_event(%Key{code: "n", modifiers: ["ctrl"]}, form)
    assert failed.overlay.error =~ "already exists"
    assert failed.overlay.error =~ "Open folder"
    assert Alto.TUI.WorkspaceForm.path(failed.overlay) == folder
    assert failed.selected_project_id == opened.selected_project_id
  end

  test "close controls hide workspaces, preserve tasks and draft, and handle the last workspace",
       context do
    state = state!(context)
    original = state.selected_project_id
    folder = Path.join(context.root, "Other")
    File.mkdir!(folder)
    {:ok, state} = State.open_workspace(state, folder)
    other = state.selected_project_id
    {:ok, task} = Alto.Harness.Catalog.create_task(other, "Saved task", state.catalog_opts)
    state = %{State.put_task(state, task) | dimensions: {150, 42}}
    ExRatatui.textarea_insert_str(state.textarea, "keep draft")
    rows = State.rail_rows(state)
    index = Enum.find_index(rows, &(&1.id == other))
    rail = View.layout(state, 150, 42).rail

    mouse = %Mouse{
      kind: "down",
      button: "left",
      x: rail.x + rail.width - 2,
      y: rail.y + 2 + index
    }

    assert View.hit_target(state, 150, 42, mouse.x, mouse.y) == {:close_workspace, other}
    {:noreply, pressed} = App.handle_event(mouse, state)
    {:noreply, closed} = App.handle_event(%{mouse | kind: "up"}, pressed)
    assert closed.selected_project_id == original
    assert closed.selected_task_id == nil
    refute Enum.any?(State.rail_rows(closed), &(&1.id in [other, task["id"]]))
    assert {:ok, [^task]} = Alto.Harness.Catalog.tasks(other, state.catalog_opts)
    assert File.dir?(folder)
    assert ExRatatui.textarea_get_value(closed.textarea) == "keep draft"
    restarted = state!(context)
    refute Enum.any?(State.rail_rows(restarted), &(&1.id == other))

    {:noreply, gear} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, closed)
    {:noreply, empty} = App.handle_event(%Key{code: "x"}, gear)
    assert empty.selected_project_id == nil
    assert State.rail_rows(empty) == []
    {:noreply, empty} = App.handle_event(%Key{code: "enter"}, empty)
    assert empty.notice =~ "Open a workspace first"
    assert ExRatatui.textarea_get_value(empty.textarea) == "keep draft"
    terminal = ExRatatui.init_test_terminal(150, 42)
    assert :ok = ExRatatui.draw(terminal, View.widgets(empty, %{width: 150, height: 42}))
    {:ok, reopened} = State.open_workspace(empty, folder)
    assert reopened.selected_project_id == other
    assert Enum.any?(State.rail_rows(reopened), &(&1.id == task["id"]))
    assert Enum.any?(State.rail_rows(reopened), &(&1.id == other))
  end

  test "workspace menu offers Close workspace without cancelling running work", context do
    state = state!(context)
    state = %{state | runs: %{"background" => %{task_id: "running", status: :running}}}
    {:noreply, gear} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, menu} = App.handle_event(%Key{code: "w"}, gear)
    index = Enum.find_index(menu.overlay.items, &(&1.value == :close_workspace))

    {:noreply, closed} =
      App.handle_event(%Key{code: "enter"}, %{menu | overlay: %{menu.overlay | index: index}})

    assert closed.runs == state.runs
    assert closed.selected_project_id == nil
    assert closed.overlay == nil
  end

  test "sidebar arrows cross workspace headers both ways and workspace clicks compose", context do
    state = state!(context)

    projects =
      Enum.map(1..3, fn n ->
        %{"id" => "p#{n}", "name" => "Project #{n}", "root" => context.root}
      end)

    tasks =
      Map.new(1..3, fn n ->
        {"p#{n}",
         [
           %{
             "id" => "t#{n}",
             "title" => "Task #{n}",
             "status" => "completed",
             "backend" => "alto"
           }
         ]}
      end)

    state = %{
      state
      | projects: projects,
        tasks: tasks,
        selected_project_id: "p2",
        selected_task_id: "t2",
        focus: :rail,
        dimensions: {150, 42}
    }

    ExRatatui.textarea_insert_str(state.textarea, "keep draft")
    {:noreply, header} = App.handle_event(%Key{code: "up"}, state)
    assert header.selected_project_id == "p2"
    assert header.selected_task_id == nil
    assert header.focus == :rail
    {:noreply, previous} = App.handle_event(%Key{code: "up"}, header)
    assert previous.selected_project_id == "p1"
    assert previous.selected_task_id == nil
    {:noreply, first} = App.handle_event(%Key{code: "up"}, previous)
    assert first.selected_project_id == "p1"
    {:noreply, task} = App.handle_event(%Key{code: "down"}, first)
    assert task.selected_task_id == "t1"
    {:noreply, next} = App.handle_event(%Key{code: "down"}, task)
    assert next.selected_project_id == "p2"
    assert next.selected_task_id == nil

    rail = View.layout(state, 150, 42).rail
    # Click the current workspace, then a different one; neither resumes an old task.
    for {row, id} <- [{1, "p2"}, {3, "p3"}] do
      mouse = %Mouse{kind: "down", button: "left", x: rail.x + 3, y: rail.y + 2 + row}
      {:noreply, pressed} = App.handle_event(mouse, state)
      {:noreply, clicked} = App.handle_event(%{mouse | kind: "up"}, pressed)
      assert clicked.selected_project_id == id
      assert clicked.selected_task_id == nil
      assert clicked.overlay == nil
      assert clicked.focus == :composer
      assert ExRatatui.textarea_get_value(clicked.textarea) == "keep draft"
    end
  end

  test "new-workspace sidebar opens the folder picker and reports invalid folders",
       context do
    state = state!(context, credentials_path: context.credentials)

    state = %{state | dimensions: {150, 42}}
    rail = View.layout(state, 150, 42).rail
    mouse = %Mouse{kind: "down", button: "left", x: rail.x + 2, y: rail.y + 1}
    {:noreply, pressed} = App.handle_event(mouse, state)
    {:noreply, form} = App.handle_event(%{mouse | kind: "up"}, pressed)
    assert form.selected_project_id == state.selected_project_id
    assert form.overlay.kind == :workspace_form
    {:noreply, invalid} = App.handle_event(%Key{code: "enter"}, form)
    assert invalid.overlay.error =~ "Enter a folder"

    {:noreply, typed} =
      App.handle_event(%ExRatatui.Event.Paste{content: "/missing/alto-workspace"}, invalid)

    {:noreply, invalid} = App.handle_event(%Key{code: "enter"}, typed)
    assert invalid.overlay.error =~ "does not exist"
    assert invalid.selected_project_id == state.selected_project_id
    {:noreply, cancelled} = App.handle_event(%Key{code: "esc"}, invalid)
    assert cancelled.overlay == nil
    assert cancelled.selected_project_id == state.selected_project_id
  end

  test "Alt opts into copying UI text in every pane; paste edits the composer", context do
    owner = self()

    state =
      state!(context,
        credentials_path: context.credentials,
        clipboard_write: fn text ->
          send(owner, {:clipboard, text})
          :ok
        end,
        clipboard_read: fn -> {:error, :unavailable} end
      )

    state = %{state | dimensions: {150, 42}}
    ExRatatui.textarea_insert_str(state.textarea, "draft text")
    layout = View.layout(state, 150, 42)

    for rect <- [
          layout.rail,
          layout.transcript,
          layout.details,
          layout.settings,
          layout.composer,
          layout.status
        ] do
      y = rect.y

      {:noreply, pressed} =
        App.handle_event(
          %Mouse{kind: "down", button: "left", modifiers: ["alt"], x: rect.x, y: y},
          state
        )

      {:noreply, selected} =
        App.handle_event(
          %Mouse{kind: "up", button: "left", x: rect.x + rect.width - 1, y: y},
          pressed
        )

      assert selected.selection.active?
      text = Alto.TUI.Selection.text(selected.selection)
      assert text != ""
      {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, selected)
      assert_receive {:clipboard, ^text}
      refute copied.selection.active?
      assert copied.clipboard_text == text
    end

    {:noreply, pasted} =
      App.handle_event(%Key{code: "v", modifiers: ["ctrl"]}, %{
        state
        | clipboard_text: "\n猫 pasted",
          focus: :transcript
      })

    assert pasted.focus == :composer
    assert ExRatatui.textarea_get_value(pasted.textarea) == "draft text\n猫 pasted"
    assert {:stop, _} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
  end

  test "workspace action stays at fixed cells through redraw, selection and copying", context do
    initial =
      state!(context,
        credentials_path: context.credentials,
        clipboard_write: fn _ -> :ok end
      )

    initial =
      State.put_entries(initial, nil, [
        %{kind: :assistant, text: "Selectable content\nsecond line"}
      ])

    for width <- [80, 150, 240] do
      frame = %{width: width, height: 42}
      state = %{initial | dimensions: {width, 42}}
      layout = View.layout(state, width, 42)
      terminal = ExRatatui.CellSession.new(width, 42)

      try do
        :ok = ExRatatui.CellSession.draw(terminal, App.render(state, frame))

        row = fn ->
          ExRatatui.CellSession.take_cells(terminal).cells
          |> Enum.filter(&(&1.row == 1 and &1.col < layout.rail.width))
          |> Enum.map(&{&1.col, &1.symbol})
        end

        baseline = row.()
        assert Enum.map_join(baseline, &elem(&1, 1)) =~ "+ New workspace"
        down = %Mouse{kind: "down", button: "left", x: layout.transcript.x + 1, y: 1}

        events = [
          down,
          %{down | kind: "drag", x: width - 1, y: 3},
          %{down | kind: "up", x: width - 1, y: 3},
          %Key{code: "c", modifiers: ["ctrl"]}
        ]

        Enum.reduce(events, state, fn event, current ->
          {:noreply, next} = App.handle_event(event, current)
          :ok = ExRatatui.CellSession.draw(terminal, App.render(next, frame))
          assert row.() == baseline
          next
        end)
      after
        ExRatatui.CellSession.close(terminal)
      end
    end
  end

  test "transcript selection scrolls from follow mode and retains its position after copying",
       context do
    state =
      state!(context,
        credentials_path: context.credentials,
        clipboard_write: fn _ -> :ok end
      )

    state =
      State.put_entries(%{state | dimensions: {150, 42}}, nil, [
        %{kind: :assistant, text: Enum.map_join(0..99, "\n", &"line #{&1}")}
      ])

    rect = View.layout(state, 150, 42).transcript
    down = %Mouse{kind: "down", button: "left", x: rect.x + 1, y: rect.y + 3}
    {:noreply, state} = App.handle_event(down, state)
    offset = state.selection.scroll.offset
    assert offset > 0
    {:noreply, state} = App.handle_event(%{down | kind: "drag", y: rect.y}, state)

    {:noreply, state} =
      App.handle_info({:tui_selection_scroll, state.selection.scroll.token}, state)

    assert state.transcript_scroll < offset
    refute state.transcript_follow?
    text = Alto.TUI.Selection.text(state.selection)
    {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
    assert copied.clipboard_text == text
    assert copied.transcript_scroll == state.transcript_scroll
  end

  test "activity stays visible and animated while waiting without output", context do
    state = state!(context)

    state = %{
      state
      | dimensions: {150, 42},
        runs: %{
          "run" => %{
            task_id: nil,
            phase: "waiting for model",
            started_at_ms: System.system_time(:millisecond) - 3000
          }
        }
    }

    frame = %{width: 150, height: 42}
    assert [{first, rect}] = View.activity_widgets(state, frame)
    assert first.text =~ "waiting for model"
    assert first.text =~ "3s"

    refute Enum.any?(
             View.selection_content(state, 150, 42),
             &Alto.TUI.Layout.contains?(&1, rect.x, rect.y)
           )

    assert {:noreply, next, render?: true} = App.handle_info(:tui_activity_tick, state)
    assert [{second, ^rect}] = View.activity_widgets(next, frame)
    refute first.text == second.text

    assert {:noreply, idle, render?: false} =
             App.handle_info(:tui_activity_tick, %{next | runs: %{}})

    assert View.activity_widgets(idle, frame) == []
  end

  test "menu filtering renders and selects the visible item and recovers from no matches",
       context do
    menu = App.open_overlay(state!(context), :approval)

    type = fn state, code ->
      {:noreply, next} = App.handle_event(%Key{code: code}, state)
      next
    end

    filtered = Enum.reduce(String.graphemes("read"), menu, &type.(&2, &1))

    popup =
      Enum.find_value(View.widgets(filtered, %{width: 120, height: 36}), fn
        {%ExRatatui.Widgets.Popup{} = popup, _rect} -> popup
        _ -> nil
      end)

    assert popup.block.title =~ "filter: read"
    assert popup.content.items == ["READ · deny prepared mutations"]
    {:noreply, selected} = App.handle_event(%Key{code: "enter"}, filtered)
    assert selected.approval_level == :read_only
    assert selected.overlay == nil

    empty = menu |> type.("z") |> type.("z")
    {:noreply, empty} = App.handle_event(%Key{code: "down"}, empty)
    {:noreply, unchanged} = App.handle_event(%Key{code: "enter"}, empty)
    assert unchanged.overlay == empty.overlay
    restored = empty |> type.("backspace") |> type.("backspace")
    assert restored.overlay == %{menu.overlay | index: 0}
  end

  test "effort picker offers only supported choices and remembers them per model", context do
    state = state!(context)

    state = %{
      state
      | models: %{
          state.selected_provider_id => [
            %{id: state.selected_model, reasoning: %{"supported_efforts" => ["low", "high"]}}
          ]
        }
    }

    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "r"}, state)
    assert Enum.map(state.overlay.items, & &1.value) == [:default, "low", "high"]
    {:noreply, state} = App.handle_event(%Key{code: "down"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    assert State.selected_effort(state) == "low"
    assert State.selected_effort(%{state | selected_model: "unsupported"}) == nil
    assert Enum.any?(View.settings_segments(state), &(&1.target == {:setting, :effort}))
    unsupported = %{state | selected_model: "unsupported", leader?: true}
    {:noreply, unsupported} = App.handle_event(%Key{code: "r"}, unsupported)
    assert unsupported.overlay == nil
    assert unsupported.notice =~ "does not advertise"
  end

  test "provider reasoning is separate from the answer and changes the activity phase", context do
    state = state!(context)

    state = %{
      state
      | selected_task_id: "task",
        runs: %{"run" => %{task_id: "task", phase: "waiting for model"}}
    }

    {:noreply, state} =
      App.handle_info(
        {:alto_tui_event, "run", Alto.Event.live(:model_reasoning_delta, %{text: "Check files"})},
        state
      )

    assert state.runs["run"].phase == "thinking"

    {:noreply, state} =
      App.handle_info(
        {:alto_tui_event, "run", Alto.Event.live(:model_delta, %{text: "Answer"})},
        state
      )

    assert state.runs["run"].phase == "receiving response"

    assert [%{kind: :reasoning, text: "Check files"}, %{kind: :assistant, text: "Answer"}] =
             State.current_entries(state)
  end

  test "canonical handoff compaction event marks context ready and shows artifacts", context do
    state = state!(context)

    state = %{
      state
      | selected_task_id: "task",
        runs: %{"run" => %{task_id: "task", phase: "compacting context"}}
    }

    event =
      Alto.Event.durable(:context_compacted, %{
        strategy: :handoff,
        files: %{design: "/tmp/DESIGN.md", pointers: "/tmp/POINTERS.md"},
        directory: "/tmp/handoff",
        next_step: "Continue from the saved design."
      })

    {:noreply, state} = App.handle_info({:alto_tui_event, "run", event}, state)

    assert state.runs["run"].phase == "context ready"

    assert [%{kind: :system, text: text}] = State.current_entries(state)
    assert text =~ "handoff created"
    assert text =~ "/tmp/DESIGN.md"
    assert text =~ "/tmp/POINTERS.md"
    assert text =~ "Continue from the saved design."
  end

  test "buffered Codex events retain run identity through phase changes and completion",
       context do
    state = state!(context)
    run = %{kind: :codex, task_id: "task", thread_id: "thread", turn_id: nil, status: :starting}
    state = App.attach_run(%{state | selected_task_id: "task"}, "run", run, "hello", "starting")
    params = %{"threadId" => "thread", "turnId" => "turn", "delta" => "Thinking"}

    pending = [
      {:notification, "item/reasoning/textDelta", params},
      {:notification, "item/agentMessage/delta", %{params | "delta" => "Answer"}},
      {:notification, "turn/completed", Map.put(params, "turn", %{"status" => "completed"})}
    ]

    state = put_in(state.backend_state[Codex].pending_messages, pending)

    assert {:noreply, state} =
             App.handle_info(
               {:codex_turn_started, "run", {:ok, %{thread_id: "thread", turn_id: "turn"}}},
               state
             )

    assert state.runs == %{}
    assert state.backend_state[Codex].pending_messages == []
    assert state.notice == "Codex run completed"

    assert Enum.any?(
             State.current_entries(state),
             &(&1.kind == :codex_assistant and &1.text == "Answer")
           )
  end

  test "Codex reasoning summaries replace raw deltas and the completed item is authoritative",
       context do
    state = state!(context)

    run = %{
      local_id: "run",
      kind: :codex,
      task_id: "task",
      thread_id: "thread",
      turn_id: "turn",
      phase: "waiting for model"
    }

    state = %{
      state
      | selected_task_id: "task",
        runs: %{"run" => run},
        backend_state:
          Map.put(state.backend_state, Alto.TUI.Backends.Codex, %{
            state.backend_state[Alto.TUI.Backends.Codex]
            | client: self()
          })
    }

    params = %{"threadId" => "thread", "turnId" => "turn", "itemId" => "reason", "delta" => "Raw"}

    {:noreply, state} =
      App.handle_info({:codex_notification, self(), "item/reasoning/textDelta", params}, state)

    {:noreply, state} =
      App.handle_info(
        {:codex_notification, self(), "item/reasoning/summaryTextDelta",
         %{params | "delta" => "Summary"}},
        state
      )

    assert [%{kind: :reasoning, text: "Summary"}] = State.current_entries(state)
    assert state.runs["run"].phase == "thinking"

    params =
      Map.put(params, "item", %{
        "id" => "reason",
        "type" => "reasoning",
        "summary" => ["Final summary"],
        "content" => ["Raw"]
      })

    {:noreply, state} =
      App.handle_info({:codex_notification, self(), "item/completed", params}, state)

    assert [%{kind: :reasoning, text: "Final summary"}] = State.current_entries(state)
  end

  test "effort selector loads a cold model catalog without visiting model selection first",
       context do
    state = state!(context)
    state = %{state | models: %{}, leader?: true}
    {:noreply, loading} = App.handle_event(%Key{code: "r"}, state)
    assert loading.overlay.kind == :effort
    assert MapSet.member?(loading.model_loading, state.selected_provider_id)
    result = {:ok, [%{id: state.selected_model, efforts: ["low", "high"]}]}

    {:noreply, loaded} =
      App.handle_info({:alto_models_loaded, state.selected_provider_id, result}, loading)

    assert Enum.map(loaded.overlay.items, & &1.value) == [:default, "low", "high"]
  end

  test "ordinary selection excludes chrome and placeholders but includes content", context do
    state =
      state!(context,
        credentials_path: context.credentials,
        clipboard_write: fn _ -> :ok end
      )

    state = %{state | dimensions: {150, 42}}
    layout = View.layout(state, 150, 42)

    for {x, y} <- [
          {1, 1},
          {layout.settings.x + 2, layout.settings.y},
          {1, 41},
          {layout.transcript.x + 2, 0},
          {layout.transcript.x + 2, 1},
          {layout.composer.x + 2, layout.composer.y + 1}
        ] do
      down = %Mouse{kind: "down", button: "left", x: x, y: y}
      {:noreply, pressed} = App.handle_event(down, state)
      assert pressed.selection.snapshot == nil
      {:noreply, dragged} = App.handle_event(%{down | kind: "up", x: x + 4}, pressed)
      refute dragged.selection.active?
      assert dragged.overlay == nil
    end

    state = State.put_entries(state, nil, [%{kind: :assistant, text: "answer text"}])
    ExRatatui.textarea_insert_str(state.textarea, "draft text")
    {:noreply, selected} = App.handle_event(%Key{code: "a", modifiers: ["ctrl", "shift"]}, state)
    copied = Alto.TUI.Selection.text(selected.selection)
    assert copied =~ "answer text"
    assert copied =~ "draft text"
    refute copied =~ "New workspace"
    refute copied =~ "new task"
    refute copied =~ "tok "
    {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, selected)
    assert copied.clipboard_text =~ "answer text"
  end

  test "popup selection copies only masked API keys and paste edits the current form", context do
    state =
      state!(context,
        credentials_path: context.credentials,
        clipboard_write: fn _ -> :ok end,
        clipboard_read: fn -> {:ok, "from clipboard"} end
      )

    {:noreply, state} = App.handle_event(%Key{code: "f3"}, state)
    # Add-provider action is exposed by the provider picker.
    index = Enum.find_index(state.overlay.items, &(&1.value == {:configure_provider, nil}))
    state = put_in(state.overlay.index, index)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    assert state.overlay.kind == :provider_form
    input = Enum.find(state.overlay.fields, &(&1.key == :api_key)).input
    ExRatatui.text_input_set_value(input, "never-copy-this-secret")
    {:noreply, selected} = App.handle_event(%Key{code: "a", modifiers: ["ctrl", "shift"]}, state)
    {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, selected)
    assert copied.overlay.kind == :provider_form
    assert copied.clipboard_text =~ "••••"
    refute copied.clipboard_text =~ "never-copy-this-secret"
    {:noreply, pasted} = App.handle_event(%Key{code: "v", modifiers: ["ctrl"]}, copied)

    assert ExRatatui.text_input_get_value(
             Enum.find(pasted.overlay.fields, &(&1.key == :id)).input
           ) =~ "from clipboard"
  end

  test "backend recovery offers only configured alternatives and selects them", context do
    for alternatives <- [[], [local: {Alto.TUI.Backends.Native, label: "Local runner"}]] do
      config =
        context.config.run_options
        |> Keyword.put(:tui_backends, [codex: {Alto.TUI.Backends.Codex, []}] ++ alternatives)
        |> Alto.Config.new()

      assert {:ok, state} = State.new(config, project: context.root, path: context.catalog)
      assert {:noreply, state} = App.handle_info({:codex_connected, {:error, :offline}}, state)
      assert length(state.overlay.items) == 1 + length(alternatives)

      if alternatives != [] do
        state = put_in(state.overlay.index, 1)
        assert {:noreply, selected} = App.handle_event(%Key{code: "enter"}, state)
        assert selected.selected_backend == :local
        assert selected.overlay == nil
      end
    end
  end

  test "Codex login lifecycle keeps prepare inert and stores login in status", context do
    config =
      context.config
      |> Map.update!(:run_options, fn options ->
        Keyword.put(options, :tui_backends, codex: {Codex, []})
      end)

    assert {:ok, state} = State.new(config, project: context.root, path: context.catalog)
    test_owner = self()
    client = start_supervised!({ControllableCodexClient, test_owner})

    state =
      state
      |> put_in([Access.key!(:backend_state), Access.key!(Codex), Access.key!(:client)], client)
      |> put_in([Access.key!(:backend_state), Access.key!(Codex), Access.key!(:status)], :ready)
      |> put_in(
        [Access.key!(:backend_state), Access.key!(Codex), Access.key!(:options)],
        open_url: fn url ->
          send(test_owner, {:codex_url_opened, url})
          :ok
        end
      )

    pending = Codex.ui({:select, :codex_login}, state, [])
    assert pending.backend_state[Codex].status == {:authenticating, :pending}
    assert_receive {:codex_login_requested, ^client}

    prepared = Codex.ui(:prepare, pending, [])
    assert prepared.backend_state[Codex].client == client
    assert prepared.backend_state[Codex].status == {:authenticating, :pending}
    refute_receive {:codex_login_requested, ^client}, 50

    login = %{"authUrl" => "https://chatgpt.test/oauth", "loginId" => "login-1"}
    send(client, {:finish_login, {:ok, login}})
    assert_receive {:codex_login_started, {:ok, ^login}}

    assert {:noreply, authenticating} =
             Codex.ui({:message, {:codex_login_started, {:ok, login}}}, prepared, [])

    assert_receive {:codex_url_opened, "https://chatgpt.test/oauth"}
    assert authenticating.backend_state[Codex].status == {:authenticating, login}
    assert authenticating.overlay.kind == :codex_account

    cancelled = Codex.ui({:select, {:codex_cancel_login, "login-1"}}, authenticating, [])
    assert cancelled.backend_state[Codex].status == :ready
    assert_receive {:codex_login_cancelled, %{"loginId" => "login-1"}}

    pending = Codex.ui({:select, :codex_login}, cancelled, [])
    assert_receive {:codex_login_requested, ^client}
    send(client, {:finish_login, {:error, :oauth_failed}})
    assert_receive {:codex_login_started, {:error, :oauth_failed}}

    assert {:noreply, failed} =
             Codex.ui(
               {:message, {:codex_login_started, {:error, :oauth_failed}}},
               pending,
               []
             )

    assert failed.backend_state[Codex].status == {:error, :oauth_failed}
    assert failed.overlay.kind == :codex_error
  end

  test "custom backends start providerless and retain configured approval", context do
    config =
      Alto.Test.TUI.config(
        provider: nil,
        approval: Alto.Approvals.DenyAll,
        tui_backends: [custom: {CustomBackend, owner: self()}],
        session_dir: Path.join(context.root, "sessions")
      )

    {:ok, project} = Alto.Harness.Catalog.register_project(context.root, path: context.catalog)

    {:ok, _task} =
      Alto.Harness.Catalog.create_task(project["id"], "custom task",
        path: context.catalog,
        backend: "custom"
      )

    app =
      start_app!(context,
        config: config,
        credentials_path: context.credentials,
        test_mode: {120, 36}
      )

    state = user_state(app)
    assert state.selected_backend == :custom
    ExRatatui.textarea_set_value(state.textarea, "execute")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})
    assert_receive {:custom_start, Alto.Approvals.DenyAll}, 2_000
    eventually(fn -> user_state(app).notice == "run completed" end)
  end

  test "display text and inactive task caches are bounded", context do
    state = state!(context)

    state =
      Enum.reduce(1..30, state, fn n, acc ->
        acc
        |> State.append_entry("task-#{n}", %{
          kind: :assistant,
          text: String.duplicate("λ", 100_000)
        })
        |> State.update_usage("task-#{n}", %{"input_tokens" => 1})
      end)

    assert map_size(state.entries) <= 12
    assert map_size(state.usage) <= 12

    assert Enum.all?(state.entries, fn {_task, entries} ->
             Enum.all?(entries, fn entry ->
               byte_size(entry.text) <= 64_000 and String.valid?(entry.text)
             end)
           end)
  end

  test "renders the agreed pane model and telemetry bar headlessly", context do
    state = state!(context)
    state = %{state | dimensions: {150, 42}}
    terminal = ExRatatui.init_test_terminal(150, 42)
    frame = %ExRatatui.Frame{width: 150, height: 42}

    assert :ok = ExRatatui.draw(terminal, View.widgets(state, frame))
    buffer = ExRatatui.get_buffer_content(terminal)

    assert buffer =~ "workspaces"
    assert buffer =~ "new task"
    assert buffer =~ "B:ALTO"
    assert buffer =~ "A:ASK"
    assert buffer =~ "P:Test Provider"
    assert buffer =~ "M:test/model"
    assert buffer =~ "cache 0.0%"
    refute buffer =~ "││ ▾"
  end

  test "transcript follows streaming output until the user scrolls away", context do
    state = state!(context)

    state =
      state
      |> Map.put(:dimensions, {80, 24})
      |> State.put_entries(nil, [
        %{kind: :user, text: "A follow-up"},
        %{kind: :assistant, text: Enum.join(List.duplicate("streaming output", 100), " ")}
      ])

    bottom = View.transcript_bottom_scroll(state)
    assert bottom > 0

    layout = View.layout(state, 80, 24)
    widget = widget_at(View.widgets(state, %{width: 80, height: 24}), layout.transcript)
    assert widget.scroll == {bottom, 0}

    paused = %{state | transcript_follow?: false, transcript_scroll: 3}
    widget = widget_at(View.widgets(paused, %{width: 80, height: 24}), layout.transcript)
    assert widget.scroll == {3, 0}
    assert widget.block.title =~ "history · G follow"
  end

  test "reopening a native task restores durable usage telemetry", context do
    session_dir = Path.join(context.root, "sessions")

    assert {:ok, project} =
             Alto.Harness.Catalog.register_project(context.root, path: context.catalog)

    assert {:ok, session_id} =
             Alto.Session.create("durable usage", %{}, session_dir: session_dir)

    event =
      Alto.Event.durable(:model_completed, %{
        message: "done",
        tool_calls: [],
        usage: %{
          input_tokens: 800,
          output_tokens: 50,
          total_tokens: 850,
          cached_input_tokens: 400,
          last_input_tokens: 800,
          requests: 1
        }
      })

    assert :ok =
             Alto.Session.append(session_id, Alto.Session.event_record("run-usage", event),
               session_dir: session_dir
             )

    assert {:ok, _task} =
             Alto.Harness.Catalog.create_task(project["id"], "durable usage",
               path: context.catalog,
               conversation_id: session_id
             )

    state = state!(context, session_dir: session_dir)

    usage = State.current_usage(state)
    assert usage.total_tokens == 850
    assert usage.cached_input_tokens == 400
    assert Alto.Usage.cache_hit_rate(usage) == 50.0
  end

  test "a Codex thread ID collision never hydrates native session history", context do
    session_dir = Path.join(context.root, "sessions")
    {:ok, project} = Alto.Harness.Catalog.register_project(context.root, path: context.catalog)
    {:ok, id} = Alto.Session.create("native secret", %{}, session_dir: session_dir)
    messages = [%{"role" => "assistant", "content" => "native-only history"}]
    {:ok, _snapshot} = Alto.Session.persist_settled(id, messages, 19, session_dir: session_dir)

    {:ok, task} =
      Alto.Harness.Catalog.create_task(project["id"], "Codex task",
        path: context.catalog,
        backend: "codex",
        conversation_id: id
      )

    state = state!(context, session_dir: session_dir)
    assert state.selected_backend == :codex
    assert State.current_entries(state) == []

    {:ok, _task} =
      Alto.Harness.Catalog.update_task(task["id"], %{"backend" => "alto"}, path: context.catalog)

    native = state!(context, session_dir: session_dir)
    assert [%{kind: :assistant, text: "native-only history"}] = State.current_entries(native)
  end

  test "narrow gear help keeps every command visible", context do
    state = state!(context)
    state = %{state | dimensions: {100, 30}, leader?: true}
    layout = View.layout(state, 100, 30)
    widget = widget_at(View.widgets(state, %{width: 100, height: 30}), layout.composer)

    assert widget.block.title =~ "B A P M R E W X T N D Q"
    assert widget.block.title =~ "Esc cancel"
    assert String.length(widget.block.title) <= layout.composer.width - 2
  end

  test "composer wraps prose by default and preserves code as an unwrapped native editor",
       context do
    state = state!(context)
    state = %{state | dimensions: {60, 22}}
    ExRatatui.textarea_set_value(state.textarea, String.duplicate("a", 70))

    layout = View.layout(state, 60, 22)
    prose_widget = widget_at(View.widgets(state, %{width: 60, height: 22}), layout.composer)
    assert %ExRatatui.Widgets.Paragraph{wrap: false} = prose_widget

    terminal = ExRatatui.init_test_terminal(60, 22)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, %{width: 60, height: 22}))
    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    assert ("│" <> String.duplicate("a", 58) <> "│") in lines
    assert ("│" <> String.pad_trailing(String.duplicate("a", 12), 58) <> "│") in lines

    code_state = %{state | composer_mode: :code}
    code_widget = widget_at(View.widgets(code_state, %{width: 60, height: 22}), layout.composer)
    assert %ExRatatui.Widgets.Textarea{} = code_widget
  end

  test "entry mode hotkeys and mouse toggle without changing the draft", context do
    app = start_app!(context, mouse_capture: true)

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "draft with a long line")

    Runtime.inject_event(app, %Key{code: "f6", kind: "press"})
    assert user_state(app).composer_mode == :code

    Runtime.inject_event(app, %Key{code: "g", kind: "press", modifiers: ["ctrl"]})
    Runtime.inject_event(app, %Key{code: "e", kind: "press"})
    assert user_state(app).composer_mode == :prose

    state = user_state(app)
    settings = View.settings_segments(state)
    entry_index = Enum.find_index(settings, &(&1.target == {:setting, :entry_mode}))
    entry_x = View.layout(state, 150, 42).settings.x

    entry_x =
      entry_x + Enum.sum(Enum.map(Enum.take(settings, entry_index), &String.length(&1.text)))

    settings_y = View.layout(state, 150, 42).settings.y

    Runtime.inject_event(app, %Mouse{
      kind: "down",
      button: "left",
      x: entry_x,
      y: settings_y
    })

    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", x: entry_x, y: settings_y})

    clicked = user_state(app)
    assert clicked.composer_mode == :code
    assert ExRatatui.textarea_get_value(clicked.textarea) == "draft with a long line"
  end

  test "focus traversal skips panes collapsed by the responsive layout", context do
    state = state!(context)
    state = %{state | dimensions: {80, 24}, focus: :transcript, details_visible?: true}

    assert State.visible_focuses(state) == [:rail, :transcript, :composer]
    assert State.focus_next(state).focus == :composer

    hidden = %{state | focus: :details}
    assert State.focus_next(hidden).focus == :composer
    assert State.focus_next(hidden, :previous).focus == :transcript
    assert State.ensure_visible_focus(hidden).focus == :transcript
  end

  test "focused context becomes a drawer on resize and hiding a pane restores focus", context do
    state = state!(context)
    state = %{state | dimensions: {150, 42}, focus: :details}

    assert {:noreply, resized} =
             App.handle_event(%ExRatatui.Event.Resize{width: 80, height: 24}, state)

    assert resized.focus == :details
    assert resized.details_drawer_open?
    assert State.visible_focuses(resized) == [:details]

    assert {:noreply, leader} =
             App.handle_event(%Key{code: "g", kind: "press", modifiers: ["ctrl"]}, state)

    assert {:noreply, hidden} = App.handle_event(%Key{code: "d", kind: "press"}, leader)
    refute hidden.details_visible?
    assert hidden.focus == :transcript
  end

  test "narrow context is a mouse-aware drawer and becomes full-screen when tiny", context do
    state = state!(context)
    state = %{state | dimensions: {80, 24}, focus: :composer}

    terminal = ExRatatui.init_test_terminal(80, 24)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, %{width: 80, height: 24}))
    assert ExRatatui.get_buffer_content(terminal) =~ "D:CTX"

    segments = View.settings_segments(state)
    context_index = Enum.find_index(segments, &(&1.target == {:setting, :details}))
    layout = View.layout(state, 80, 24)

    context_x =
      layout.settings.x +
        Enum.sum(Enum.map(Enum.take(segments, context_index), &String.length(&1.text)))

    assert {:noreply, drawer} =
             App.handle_event(
               %Mouse{
                 kind: "down",
                 button: "left",
                 x: context_x,
                 y: layout.settings.y
               },
               state
             )

    {:noreply, drawer} =
      App.handle_event(
        %Mouse{kind: "up", button: "left", x: context_x, y: layout.settings.y},
        drawer
      )

    assert drawer.details_drawer_open?
    assert drawer.details_return_focus == :composer
    assert drawer.focus == :details

    assert %ExRatatui.Layout.Rect{x: 20, y: 0, width: 60, height: 23} =
             View.context_overlay_rect(drawer, 80, 24)

    assert State.focus_next(drawer).focus == :details

    terminal = ExRatatui.init_test_terminal(80, 24)
    assert :ok = ExRatatui.draw(terminal, View.widgets(drawer, %{width: 80, height: 24}))
    buffer = ExRatatui.get_buffer_content(terminal)
    assert buffer =~ "click header / Esc close"

    assert {:noreply, closed} =
             App.handle_event(%Mouse{kind: "down", button: "left", x: 5, y: 10}, drawer)

    {:noreply, closed} = App.handle_event(%Mouse{kind: "up", button: "left", x: 5, y: 10}, closed)

    refute closed.details_drawer_open?
    assert closed.focus == :composer

    fullscreen = %{drawer | dimensions: {60, 24}}

    assert %ExRatatui.Layout.Rect{x: 0, y: 0, width: 60, height: 23} =
             View.context_overlay_rect(fullscreen, 60, 24)

    forced_drawer = %{fullscreen | narrow_context: :drawer}

    assert %ExRatatui.Layout.Rect{x: 15, y: 0, width: 45, height: 23} =
             View.context_overlay_rect(forced_drawer, 60, 24)

    forced_fullscreen = %{drawer | narrow_context: :fullscreen}

    assert %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 23} =
             View.context_overlay_rect(forced_fullscreen, 80, 24)

    tiny = %{state | dimensions: {40, 20}}
    tiny_settings = View.settings_segments(tiny)
    assert Enum.map(tiny_settings, & &1.target) == Enum.map(segments, & &1.target)
    assert tiny_settings |> Enum.map_join(& &1.text) |> String.length() <= 40
  end

  test "printable keys compose from panes by default and can preserve panel navigation",
       context do
    state = state!(context)
    state = %{state | focus: :rail}

    assert {:noreply, composing} = App.handle_event(%Key{code: "x", kind: "press"}, state)
    assert composing.focus == :composer
    assert ExRatatui.textarea_get_value(composing.textarea) == "x"

    paste_state = %{state | focus: :transcript}

    assert {:noreply, pasted} =
             App.handle_event(%ExRatatui.Event.Paste{content: "paste"}, paste_state)

    assert pasted.focus == :composer
    assert ExRatatui.textarea_get_value(pasted.textarea) == "xpaste"

    config =
      context.config.run_options
      |> Keyword.put(:tui, type_to_compose: false)
      |> Alto.Test.TUI.config()

    assert {:ok, navigating} =
             State.new(config, project: context.root, path: context.catalog)

    navigating = %{navigating | focus: :rail}
    assert {:noreply, navigating} = App.handle_event(%Key{code: "x", kind: "press"}, navigating)
    assert navigating.focus == :rail
    assert ExRatatui.textarea_get_value(navigating.textarea) == ""

    assert {:noreply, ignored, render?: false} =
             App.handle_event(%ExRatatui.Event.Paste{content: "paste"}, navigating)

    assert ExRatatui.textarea_get_value(ignored.textarea) == ""
  end

  test "gear overlays preserve the composer and a run updates durable task usage", context do
    app = start_app!(context)

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "Keep this draft")

    Runtime.inject_event(app, %Key{code: "g", kind: "press", modifiers: ["ctrl"]})
    Runtime.inject_event(app, %Key{code: "p", kind: "press"})

    overlay_state = user_state(app)
    assert overlay_state.overlay.kind == :provider
    assert ExRatatui.textarea_get_value(overlay_state.textarea) == "Keep this draft"

    Runtime.inject_event(app, %Key{code: "esc", kind: "press"})
    ExRatatui.textarea_set_value(overlay_state.textarea, "Run the task")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn ->
      done = user_state(app)
      task = State.selected_task(done)
      usage = State.current_usage(done)

      task && task["status"] == "completed" && usage.total_tokens == 1_020 &&
        usage.cached_input_tokens == 600
    end)
  end

  test "mouse settings and seam dragging use the same state model", context do
    app = start_app!(context, mouse_capture: true)

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "untouched")

    state = user_state(app)
    settings = View.settings_segments(state)
    approval_index = Enum.find_index(settings, &(&1.target == {:setting, :approval}))
    layout = View.layout(state, 150, 42)

    approval_x =
      layout.settings.x +
        Enum.sum(Enum.map(Enum.take(settings, approval_index), &String.length(&1.text)))

    Runtime.inject_event(app, %Mouse{
      kind: "down",
      button: "left",
      x: approval_x,
      y: layout.settings.y
    })

    Runtime.inject_event(app, %Mouse{
      kind: "up",
      button: "left",
      x: approval_x,
      y: layout.settings.y
    })

    clicked = user_state(app)
    assert clicked.overlay.kind == :approval
    assert ExRatatui.textarea_get_value(clicked.textarea) == "untouched"

    Runtime.inject_event(app, %Key{code: "esc", kind: "press"})
    Runtime.inject_event(app, %Mouse{kind: "down", button: "left", x: 25, y: 10})
    Runtime.inject_event(app, %Mouse{kind: "drag", button: "left", x: 31, y: 10})
    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", x: 31, y: 10})

    assert user_state(app).rail_width == 32

    Runtime.inject_event(app, %Mouse{
      kind: "down",
      button: "left",
      modifiers: ["alt"],
      x: 31,
      y: 10
    })

    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", modifiers: ["alt"], x: 31, y: 10})

    assert user_state(app).dragging == nil
  end

  test "provider failures and structured tool details render readable fields", context do
    state = state!(context)

    reason =
      {:http_error, 400,
       %{
         "error" => %{
           "message" => "Model does not support tools",
           "code" => "unsupported_parameter"
         }
       }}

    {:noreply, failed} = App.handle_info({:alto_models_loaded, "test", {:error, reason}}, state)
    assert failed.overlay.message =~ "Provider returned HTTP 400"
    assert failed.overlay.message =~ "Model does not support tools"
    refute failed.overlay.message =~ "%{"
    refute failed.overlay.message =~ "=>"
    terminal = ExRatatui.init_test_terminal(150, 42)
    ExRatatui.draw(terminal, View.widgets(failed, %{width: 150, height: 42}))
    assert ExRatatui.get_buffer_content(terminal) =~ "Model does not support tools"

    task = %{
      "id" => "display",
      "project_id" => state.selected_project_id,
      "title" => "Display",
      "status" => "failed"
    }

    state =
      state
      |> State.put_task(task)
      |> State.put_entries("display", [
        %{kind: :error, text: %{message: "Request failed", reason: :eacces}},
        %{kind: :tool, text: "Command finished", detail: %{exit_code: 1, stderr: "Missing file"}}
      ])

    ExRatatui.draw(terminal, View.widgets(state, %{width: 150, height: 42}))
    buffer = ExRatatui.get_buffer_content(terminal)
    assert buffer =~ "Permission denied"
    assert buffer =~ "Exit code: 1"
    assert buffer =~ "Stderr: Missing file"
    refute buffer =~ "%{"
    refute buffer =~ "=>"
  end

  test "a failed model discovery remains open with recovery actions", context do
    config =
      Alto.Test.TUI.config(
        provider_profiles: [
          [id: "broken", label: "Broken", provider: FailingProvider, models: :discover]
        ],
        loop: Alto.chat_loop(),
        tools: []
      )

    app =
      start_app!(context,
        config: config,
        credentials_path: context.credentials,
        test_mode: {120, 36}
      )

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "Hi")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> user_state(app).overlay.kind == :model_error end)
    Process.sleep(80)

    failed = user_state(app)
    assert failed.overlay.kind == :model_error
    assert failed.overlay.message =~ "API key is missing"
    assert failed.overlay.message =~ "[REDACTED]"
    refute failed.overlay.message =~ "should-not-render"
    assert Enum.any?(failed.overlay.items, &(&1.value == {:retry_models, "broken"}))
    assert ExRatatui.textarea_get_value(failed.textarea) == "Hi"
  end

  test "editing a configured provider preserves its options and model catalog", context do
    config =
      Alto.Test.TUI.config(
        provider_profiles: [
          [
            id: "local",
            label: "Local",
            provider:
              {Alto.Providers.OpenAICompatible, base_url: "http://old.test/v1", timeout: 777},
            models: ["original"],
            default_model: "original"
          ]
        ]
      )

    app = start_app!(context, config: config, credentials_path: context.credentials)
    Runtime.inject_event(app, %Key{code: "f3", kind: "press"})
    menu = user_state(app).overlay
    assert Enum.any?(menu.items, &(&1.value == {:configure_provider, "local"}))
    Runtime.inject_event(app, %Key{code: "up", kind: "press"})
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})
    form = user_state(app).overlay
    assert form.kind == :provider_form

    for field <- form.fields, field.key in [:label, :base_url, :model] do
      value = %{label: "Updated", base_url: "http://new.test/v1", model: "new-model"}[field.key]
      ExRatatui.text_input_set_value(field.input, value)
    end

    Runtime.inject_event(app, %Key{code: "s", modifiers: ["ctrl"], kind: "press"})
    saved = user_state(app)
    assert saved.overlay == nil
    assert saved.selected_model == "new-model"
    [profile] = saved.profiles
    assert profile.label == "Updated"
    assert profile.models == [%{id: "original", name: "original"}]
    assert {Alto.Providers.OpenAICompatible, options} = profile.provider
    assert options[:timeout] == 777
    assert options[:base_url] == "http://new.test/v1"
    refute Keyword.has_key?(options, :api_key)
  end

  test "provider setup masks and privately persists API keys", context do
    config =
      Alto.Test.TUI.config(
        provider_profiles: [
          [
            id: "openrouter",
            label: "OpenRouter",
            provider:
              {Alto.Providers.OpenAICompatible,
               base_url: "https://openrouter.ai/api/v1", model: "existing/model"},
            models: ["existing/model"]
          ]
        ],
        loop: Alto.chat_loop(),
        tools: []
      )

    app = start_app!(context, config: config, credentials_path: context.credentials)

    Runtime.inject_event(app, %Key{code: "f3", kind: "press"})
    Runtime.inject_event(app, %Key{code: "down", kind: "press"})
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    form = user_state(app)
    assert form.overlay.kind == :provider_form
    assert form.overlay.field_index == 0

    values = %{
      id: "acme",
      label: "Acme AI",
      base_url: "https://models.acme.test/v1",
      api_key: "super-secret-key",
      model: "acme/coder"
    }

    Enum.each(form.overlay.fields, fn field ->
      ExRatatui.text_input_set_value(field.input, Map.fetch!(values, field.key))
    end)

    terminal = ExRatatui.init_test_terminal(150, 42)
    frame = %ExRatatui.Frame{width: 150, height: 42}
    assert :ok = ExRatatui.draw(terminal, View.widgets(form, frame))
    buffer = ExRatatui.get_buffer_content(terminal)

    refute buffer =~ "super-secret-key"
    assert buffer =~ "••••"
    refute inspect(form) =~ "super-secret-key"

    # The form uses the same geometry for rendering and mouse routing.
    Runtime.inject_event(app, %Mouse{kind: "down", button: "left", x: 25, y: 13})
    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", x: 25, y: 13})
    assert user_state(app).overlay.field_index == 3
    Runtime.inject_event(app, %Mouse{kind: "down", button: "left", x: 25, y: 16})
    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", x: 25, y: 16})
    saved = user_state(app)

    assert saved.overlay == nil
    assert saved.selected_provider_id == "acme"

    %{provider: {Alto.Providers.OpenAICompatible, options}} =
      Enum.find(saved.profiles, &(&1.id == "acme"))

    refute Keyword.has_key?(options, :api_key)
    assert {:ok, credentials} = Alto.Credentials.load(context.credentials)
    assert Alto.Credentials.get(credentials, "acme", "api_key") == "super-secret-key"
    assert {:ok, %{mode: mode}} = File.stat(context.credentials)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "Codex is a distinct OAuth backend with approvals and telemetry", context do
    test_owner = self()

    config =
      Alto.Test.TUI.config(
        codex_backend: [
          command: context.codex_server,
          args: [],
          cwd: context.root,
          request_timeout: 5_000,
          startup_timeout: 5_000,
          open_url: fn url ->
            send(test_owner, {:opened_oauth, url})
            :ok
          end
        ],
        provider_profiles: [
          [id: "test", label: "Test Provider", provider: Provider, models: ["test/model"]]
        ],
        loop: Alto.chat_loop(),
        tools: [],
        sessions: true
      )

    app = start_app!(context, config: config, test_mode: {170, 44})

    Runtime.inject_event(app, %Key{code: "f5", kind: "press"})
    Runtime.inject_event(app, %Key{code: "down", kind: "press"})
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> match?(%{kind: :codex_account}, user_state(app).overlay) end)
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    assert_receive {:opened_oauth, "https://chatgpt.test/oauth"}, 2_000

    eventually(fn ->
      state = user_state(app)

      state.selected_backend == :codex and
        state.backend_state[Alto.TUI.Backends.Codex].status == :ready and
        state.selected_model == "gpt-test"
    end)

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "Use the subscription")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> user_state(app).pending_approvals != [] end)
    assert File.exists?(Path.join(context.root, "evicted-approval-rejected"))
    Runtime.inject_event(app, %Key{code: "f8", kind: "press"})

    eventually(fn ->
      state = user_state(app)
      task = State.selected_task(state)
      usage = State.current_usage(state)

      task && task["status"] == "completed" && task["backend"] == "codex" &&
        task["conversation_id"] == "thr-tui" && usage.total_tokens == 1_010 &&
        usage.cached_input_tokens == 600
    end)

    rendered = user_state(app)
    terminal = ExRatatui.init_test_terminal(170, 44)
    frame = %ExRatatui.Frame{width: 170, height: 44}
    assert :ok = ExRatatui.draw(terminal, View.widgets(rendered, frame))
    buffer = ExRatatui.get_buffer_content(terminal)
    assert buffer =~ "B:CODEX"
    assert buffer =~ "quota 22.0%"
    assert buffer =~ "cache 60.0%"
  end

  defp state!(context, opts \\ []) do
    defaults = [project: context.root, path: context.catalog]
    assert {:ok, state} = State.new(context.config, Keyword.merge(defaults, opts))
    state
  end

  defp start_app!(context, opts \\ []) do
    defaults = [
      config: context.config,
      project: context.root,
      path: context.catalog,
      test_mode: {150, 42},
      name: nil
    ]

    assert {:ok, app} = App.start_link(Keyword.merge(defaults, opts))
    Process.unlink(app)
    on_exit(fn -> if Process.alive?(app), do: GenServer.stop(app) end)
    app
  end

  defp user_state(app), do: :sys.get_state(app).user_state

  defp widget_at(widgets, rect) do
    widgets
    |> Enum.find(fn {_widget, area} -> area == rect end)
    |> elem(0)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp folder_form(state) do
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "w"}, state)
    # Filtering uses the same command picker as all other gear commands.
    {:noreply, state} = App.handle_event(%Key{code: "o"}, state)
    index = Enum.find_index(state.overlay.items, &(&1.value == :new_workspace))

    {:noreply, form} =
      App.handle_event(%Key{code: "enter"}, %{state | overlay: %{state.overlay | index: index}})

    form
  end
end
