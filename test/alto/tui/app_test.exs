defmodule Alto.TUI.AppTest do
  use ExUnit.Case, async: false

  alias Alto.TUI.{App, State, View}
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

    def cancel(handle, reason, _opts), do: Alto.cancel(handle, reason)
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
              IO.puts(JSON.encode!(%{"id" => id, "result" => %{"turn" => %{"id" => "turn-tui", "status" => "inProgress"}}}))
              IO.puts(JSON.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "msg", "delta" => "Working. "}}))
              IO.puts(JSON.encode!(%{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "tokenUsage" => %{"modelContextWindow" => 100_000, "last" => %{"inputTokens" => 1_000, "outputTokens" => 10, "cachedInputTokens" => 600, "reasoningOutputTokens" => 0, "totalTokens" => 1_010, "cacheWriteInputTokens" => 0}, "total" => %{"inputTokens" => 1_000, "outputTokens" => 10, "cachedInputTokens" => 600, "reasoningOutputTokens" => 0, "totalTokens" => 1_010, "cacheWriteInputTokens" => 0}}}}))
              IO.puts(JSON.encode!(%{"id" => "approval-1", "method" => "item/commandExecution/requestApproval", "params" => %{"threadId" => "thr-tui", "turnId" => "turn-tui", "itemId" => "cmd", "command" => "mix test", "cwd" => #{inspect(root)}}}))
              %{state | pending_turn: true}
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
      Alto.Config.new(
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

  test "custom backends start providerless and retain configured approval", context do
    config =
      Alto.Config.new(
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

    {:ok, app} =
      App.start_link(
        config: config,
        project: context.root,
        path: context.catalog,
        credentials_path: context.credentials,
        test_mode: {120, 36},
        name: nil
      )

    on_exit(fn -> if Process.alive?(app), do: GenServer.stop(app) end)
    state = user_state(app)
    assert state.selected_backend == :custom
    ExRatatui.textarea_set_value(state.textarea, "execute")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})
    assert_receive {:custom_start, Alto.Approvals.DenyAll}, 2_000
    eventually(fn -> user_state(app).notice == "run completed" end)
    Process.unlink(app)
    GenServer.stop(app)
  end

  test "display text and inactive task caches are bounded", context do
    {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)

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
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
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
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)

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
               session_id: session_id
             )

    assert {:ok, state} =
             State.new(context.config,
               project: context.root,
               path: context.catalog,
               session_dir: session_dir
             )

    usage = State.current_usage(state)
    assert usage.total_tokens == 850
    assert usage.cached_input_tokens == 400
    assert Alto.Usage.cache_hit_rate(usage) == 50.0
  end

  test "narrow gear help keeps every command visible", context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
    state = %{state | dimensions: {100, 30}, leader?: true}
    layout = View.layout(state, 100, 30)
    widget = widget_at(View.widgets(state, %{width: 100, height: 30}), layout.composer)

    assert widget.block.title =~ "B A P M E W T N D Q"
    assert widget.block.title =~ "Esc cancel"
    assert String.length(widget.block.title) <= layout.composer.width - 2
  end

  test "composer wraps prose by default and preserves code as an unwrapped native editor",
       context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
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
    assert {:ok, app} =
             App.start_link(
               config: context.config,
               project: context.root,
               path: context.catalog,
               test_mode: {150, 42},
               name: nil,
               mouse_capture: true
             )

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

    clicked = user_state(app)
    assert clicked.composer_mode == :code
    assert ExRatatui.textarea_get_value(clicked.textarea) == "draft with a long line"

    Process.unlink(app)
    GenServer.stop(app)
  end

  test "focus traversal skips panes collapsed by the responsive layout", context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
    state = %{state | dimensions: {80, 24}, focus: :transcript, details_visible?: true}

    assert State.visible_focuses(state) == [:rail, :transcript, :composer]
    assert State.focus_next(state).focus == :composer

    hidden = %{state | focus: :details}
    assert State.focus_next(hidden).focus == :composer
    assert State.focus_next(hidden, :previous).focus == :transcript
    assert State.ensure_visible_focus(hidden).focus == :transcript
  end

  test "focused context becomes a drawer on resize and hiding a pane restores focus", context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
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
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
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

  test "narrow approvals can auto-open and close the context drawer", context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
    state = %{state | dimensions: {80, 24}, focus: :composer}
    request = %{id: "approval-1", tool: "git_mutate", arguments: %{}, details: %{}}

    assert {:noreply, prompted} =
             App.handle_info({:alto_approval_request, "run-1", request, self()}, state)

    assert prompted.details_drawer_open?
    assert prompted.details_drawer_auto_opened?
    assert prompted.focus == :details

    terminal = ExRatatui.init_test_terminal(80, 24)
    assert :ok = ExRatatui.draw(terminal, View.widgets(prompted, %{width: 80, height: 24}))
    approval_buffer = ExRatatui.get_buffer_content(terminal)
    assert approval_buffer =~ "approval required"
    assert approval_buffer =~ "git_mutate"

    assert {:noreply, decided} = App.handle_event(%Key{code: "f8", kind: "press"}, prompted)
    assert_receive {:alto_approval_decision, "approval-1", :approve}
    refute decided.details_drawer_open?
    assert decided.focus == :composer

    config =
      context.config.run_options
      |> Keyword.put(:tui, approval_auto_open: false)
      |> Alto.Config.new()

    assert {:ok, quiet} = State.new(config, project: context.root, path: context.catalog)
    quiet = %{quiet | dimensions: {80, 24}, focus: :composer}

    assert {:noreply, quiet} =
             App.handle_info(
               {:alto_approval_request, "run-2", %{request | id: "approval-2"}, self()},
               quiet
             )

    refute quiet.details_drawer_open?
    assert quiet.focus == :composer

    terminal = ExRatatui.init_test_terminal(80, 24)
    assert :ok = ExRatatui.draw(terminal, View.widgets(quiet, %{width: 80, height: 24}))
    assert ExRatatui.get_buffer_content(terminal) =~ "D:REQ"
  end

  test "printable keys compose from panes by default and can preserve panel navigation",
       context do
    assert {:ok, state} = State.new(context.config, project: context.root, path: context.catalog)
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
      |> Alto.Config.new()

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
    assert {:ok, app} =
             App.start_link(
               config: context.config,
               project: context.root,
               path: context.catalog,
               test_mode: {150, 42},
               name: nil
             )

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

    Process.unlink(app)
    GenServer.stop(app)
  end

  test "mouse settings and seam dragging use the same state model", context do
    assert {:ok, app} =
             App.start_link(
               config: context.config,
               project: context.root,
               path: context.catalog,
               test_mode: {150, 42},
               name: nil,
               mouse_capture: true
             )

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

    clicked = user_state(app)
    assert clicked.overlay.kind == :approval
    assert ExRatatui.textarea_get_value(clicked.textarea) == "untouched"

    Runtime.inject_event(app, %Key{code: "esc", kind: "press"})
    Runtime.inject_event(app, %Mouse{kind: "down", button: "left", x: 25, y: 10})
    Runtime.inject_event(app, %Mouse{kind: "drag", button: "left", x: 31, y: 10})
    Runtime.inject_event(app, %Mouse{kind: "up", button: "left", x: 31, y: 10})

    assert user_state(app).rail_width == 32

    Process.unlink(app)
    GenServer.stop(app)
  end

  test "a failed model discovery remains open with recovery actions", context do
    config =
      Alto.Config.new(
        provider_profiles: [
          [id: "broken", label: "Broken", provider: FailingProvider, models: :discover]
        ],
        loop: Alto.chat_loop(),
        tools: []
      )

    assert {:ok, app} =
             App.start_link(
               config: config,
               project: context.root,
               path: context.catalog,
               credentials_path: context.credentials,
               test_mode: {120, 36},
               name: nil
             )

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "Hi")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> user_state(app).overlay.kind == :model_error end)
    Process.sleep(80)

    failed = user_state(app)
    assert failed.overlay.kind == :model_error
    assert failed.overlay.message =~ "api_key_missing"
    assert failed.overlay.message =~ "[REDACTED]"
    refute failed.overlay.message =~ "should-not-render"
    assert Enum.any?(failed.overlay.items, &(&1.value == {:retry_models, "broken"}))
    assert ExRatatui.textarea_get_value(failed.textarea) == "Hi"

    Process.unlink(app)
    GenServer.stop(app)
  end

  test "provider setup masks and privately persists API keys", context do
    config =
      Alto.Config.new(
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

    assert {:ok, app} =
             App.start_link(
               config: config,
               project: context.root,
               path: context.catalog,
               credentials_path: context.credentials,
               test_mode: {150, 42},
               name: nil
             )

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
    assert user_state(app).overlay.field_index == 3
    Runtime.inject_event(app, %Mouse{kind: "down", button: "left", x: 25, y: 16})
    saved = user_state(app)

    assert saved.overlay == nil
    assert saved.selected_provider_id == "acme"
    assert Enum.find(saved.profiles, &(&1.id == "acme")).options[:api_key] == nil
    assert {:ok, credentials} = Alto.Credentials.load(context.credentials)
    assert Alto.Credentials.get(credentials, "acme", "api_key") == "super-secret-key"
    assert {:ok, %{mode: mode}} = File.stat(context.credentials)
    assert Bitwise.band(mode, 0o077) == 0

    Process.unlink(app)
    GenServer.stop(app)
  end

  test "Codex is a distinct OAuth backend with approvals and telemetry", context do
    test_owner = self()

    config =
      Alto.Config.new(
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

    assert {:ok, app} =
             App.start_link(
               config: config,
               project: context.root,
               path: context.catalog,
               test_mode: {170, 44},
               name: nil
             )

    Runtime.inject_event(app, %Key{code: "f5", kind: "press"})
    Runtime.inject_event(app, %Key{code: "down", kind: "press"})
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> user_state(app).overlay.kind == :codex_account end)
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    assert_receive {:opened_oauth, "https://chatgpt.test/oauth"}, 2_000

    eventually(fn ->
      state = user_state(app)

      state.selected_backend == :codex and state.codex.status == :ready and
        state.selected_model == "gpt-test"
    end)

    state = user_state(app)
    ExRatatui.textarea_set_value(state.textarea, "Use the subscription")
    Runtime.inject_event(app, %Key{code: "enter", kind: "press"})

    eventually(fn -> user_state(app).pending_approvals != [] end)
    Runtime.inject_event(app, %Key{code: "f8", kind: "press"})

    eventually(fn ->
      state = user_state(app)
      task = State.selected_task(state)
      usage = State.current_usage(state)

      task && task["status"] == "completed" && task["backend"] == "codex" &&
        task["backend_thread_id"] == "thr-tui" && usage.total_tokens == 1_010 &&
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

    Process.unlink(app)
    GenServer.stop(app)
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
end
