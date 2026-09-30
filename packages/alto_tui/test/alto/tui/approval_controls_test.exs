defmodule Alto.TUI.ApprovalControlsTest do
  use ExUnit.Case, async: false

  alias Alto.TUI.App
  alias Alto.TUI.State
  alias Alto.TUI.View
  alias ExRatatui.Event.Mouse

  defmodule Provider do
    @behaviour Alto.Provider

    def describe(opts), do: %{model: opts[:model], context_window: 100_000}
    def list_models(_opts), do: {:ok, []}
    def stream(_request, _sink, _opts), do: {:error, :not_used}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-approval-controls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    config =
      Alto.Test.TUI.config(
        provider_profiles: [
          %Alto.Contrib.ProviderProfile{
            id: "test",
            label: "Test",
            provider: {Provider, model: "test/model"}
          }
        ],
        loop: Alto.chat_loop(),
        tools: [],
        tui: [approval_auto_open: true]
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, catalog: Path.join(root, "catalog.json"), config: config}
  end

  test "protocol reviewers normalize decisions and fail closed without blocking the UI",
       context do
    owner = self()

    for {reviewer, expected} <- [
          {fn _, _ -> true end, :approve},
          {fn _, _ -> false end, {:deny, :reviewer_denied}},
          {fn _, _ -> :unexpected end, {:deny, :invalid_reviewer_decision}},
          {fn _, _ -> raise "classifier failed" end, {:deny, :reviewer_failed}},
          {fn _, _ -> Process.sleep(:infinity) end, {:deny, :reviewer_timeout}}
        ] do
      initial = pending_state(context, {140, 40})
      request = %{id: "codex-review", tool: "command", arguments: %{}, details: %{}}

      pending = %{
        local_id: "codex-run",
        request: request,
        review_context: %{cwd: context.root, session_id: "thread", metadata: %{}},
        respond: fn decision -> send(owner, {:review_decision, decision}) end
      }

      options =
        initial.run_options
        |> Keyword.put(:tui, approval_reviewer: reviewer)
        |> Keyword.put(:approval_timeout, 100)

      initial = %{initial | run_options: options, pending_approvals: [], approval_level: :review}
      reviewing = App.route_approval(initial, pending)
      assert reviewing.pending_approvals == []
      assert map_size(reviewing.approval_reviews) == 1
      assert_receive {:alto_approval_reviewed, "codex-review", ^expected} = result, 1_000
      {:noreply, finished} = App.handle_info(result, reviewing)
      assert_receive {:review_decision, ^expected}
      assert finished.approval_reviews == %{}
      {:noreply, ^finished} = App.handle_info(result, finished)
      refute_receive {:review_decision, _}, 10
    end
  end

  test "cancelling a run kills its classifier immediately and discards late decisions", context do
    owner = self()

    reviewer = fn _, _ ->
      send(owner, {:review_started, self()})
      Process.sleep(:infinity)
    end

    initial = pending_state(context, {140, 40})

    pending = %{
      local_id: "codex-run",
      request: %{id: "codex-review"},
      review_context: %{},
      respond: fn decision -> send(owner, {:review_decision, decision}) end
    }

    initial = %{
      initial
      | pending_approvals: [],
        approval_level: :review,
        run_options: Keyword.put(initial.run_options, :tui, approval_reviewer: reviewer)
    }

    reviewing = App.route_approval(initial, pending)
    assert_receive {:review_started, pid}
    monitor = Process.monitor(pid)

    reviewing = %{
      reviewing
      | focus: :composer,
        details_return_focus: nil,
        runs: %{"codex-run" => %{local_id: "codex-run", task_id: reviewing.selected_task_id}}
    }

    {:noreply, stopped} = App.handle_event(%ExRatatui.Event.Key{code: "esc"}, reviewing)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert stopped.approval_reviews == %{}

    {:noreply, ^stopped} =
      App.handle_info({:alto_approval_reviewed, "codex-review", :approve}, stopped)

    refute_receive {:review_decision, _}, 10
  end

  test "approval hotkeys preserve context or the pane the user chose", context do
    for dimensions <- [{140, 40}, {80, 24}], code <- ["f8", "f9"] do
      state = pending_state(context, dimensions)
      {:noreply, decided} = App.handle_event(%ExRatatui.Event.Key{code: code}, state)
      assert_receive {:alto_approval_decision, "approval-1", _}
      assert decided.focus == :details
      assert decided.details_return_focus == state.details_return_focus
      refute decided.details_drawer_auto_opened?
      # A subsequent resolved event must not close a drawer the user is using.
      resolved = App.drop_run(decided, "run-1")
      assert resolved.focus == :details
      assert resolved.details_return_focus == state.details_return_focus
    end

    for focus <- [:composer, :transcript, :rail] do
      state = %{pending_state(context, {140, 40}) | focus: focus}
      {:noreply, decided} = App.handle_event(%ExRatatui.Event.Key{code: "f8"}, state)
      assert_receive {:alto_approval_decision, "approval-1", :approve}
      assert decided.focus == focus
    end
  end

  test "leaving a subagent returns to context and closing a drawer is explicit", context do
    for dimensions <- [{140, 40}, {80, 24}] do
      state = %{
        pending_state(context, dimensions)
        | pending_approvals: [],
          selected_agent_id: "child",
          details_scroll: 50
      }

      ExRatatui.textarea_set_value(state.textarea, "draft")
      {:noreply, context_view} = App.handle_event(%ExRatatui.Event.Key{code: "esc"}, state)
      assert context_view.selected_agent_id == nil
      assert context_view.details_scroll == 0
      assert context_view.focus == :details
      assert context_view.details_return_focus == state.details_return_focus
      assert ExRatatui.textarea_get_value(context_view.textarea) == "draft"

      if state.details_return_focus do
        {:noreply, closed} = App.handle_event(%ExRatatui.Event.Key{code: "esc"}, context_view)
        assert closed.focus == :composer
        assert closed.details_return_focus == nil
      else
        assert State.close_details_drawer(context_view) == context_view
      end
    end
  end

  test "renders labeled desktop controls and accepts clicks on their labels", context do
    state = pending_state(context, {140, 40})
    {buffer, _terminal} = render(state, 140, 40)
    assert {:ok, approve} = label_position(buffer, "[ Approve F8 ]")
    assert {:ok, deny} = label_position(buffer, "[ Deny F9 ]")
    assert approve.y < deny.y

    approve_event = click_at(approve, "[ Approve F8 ]")

    assert View.hit_target(state, 140, 40, approve_event.x, approve_event.y) ==
             {:approval, :approve}

    assert {:noreply, decided} = click(approve_event, state)
    assert_receive {:alto_approval_decision, "approval-1", :approve}
    assert decided.pending_approvals == []
    assert decided.focus == :details

    state = pending_state(context, {140, 40})
    {buffer, _terminal} = render(state, 140, 40)
    {:ok, deny} = label_position(buffer, "[ Deny F9 ]")

    assert {:noreply, decided} = click(click_at(deny, "[ Deny F9 ]"), state)
    assert_receive {:alto_approval_decision, "approval-1", {:deny, :user_denied}}
    assert decided.pending_approvals == []
  end

  test "blank space and the details bottom border never decide an approval", context do
    state = pending_state(context, {140, 40})
    layout = View.layout(state, 140, 40)
    {buffer, _terminal} = render(state, 140, 40)
    {:ok, approve} = label_position(buffer, "[ Approve F8 ]")

    blank_x = approve.x + String.length("[ Approve F8 ]") + 1

    assert {:noreply, unchanged} =
             click(
               %Mouse{kind: "down", button: "left", x: blank_x, y: approve.y},
               state
             )

    assert unchanged.pending_approvals == state.pending_approvals
    refute_receive {:alto_approval_decision, "approval-1", _decision}, 100

    assert {:noreply, unchanged} =
             click(
               %Mouse{
                 kind: "down",
                 button: "left",
                 x: blank_x,
                 y: layout.details.y + layout.details.height - 1
               },
               state
             )

    assert unchanged.pending_approvals == state.pending_approvals
    refute_receive {:alto_approval_decision, "approval-1", _decision}, 100
  end

  test "keeps drawer controls pinned while details scrolls and accepts a narrow click", context do
    state = pending_state(context, {80, 24})
    assert state.details_return_focus
    assert state.details_drawer_auto_opened?
    assert state.focus == :details
    scrolled = %{state | details_scroll: 100}
    {buffer, _terminal} = render(scrolled, 80, 24)

    assert {:ok, approve} = label_position(buffer, "[ Approve F8 ]")
    assert {:ok, deny} = label_position(buffer, "[ Deny F9 ]")
    assert approve.y < deny.y

    assert {:noreply, decided} = click(click_at(deny, "[ Deny F9 ]"), scrolled)
    assert_receive {:alto_approval_decision, "approval-1", {:deny, :user_denied}}
    assert decided.pending_approvals == []
    assert decided.details_return_focus == :composer
    assert decided.focus == :details
    refute decided.details_drawer_auto_opened?
    {:noreply, closed} = App.handle_event(%ExRatatui.Event.Key{code: "esc"}, decided)
    assert closed.focus == :composer
    assert closed.details_return_focus == nil
  end

  test "dragging approval labels does not select UI text or send a decision", context do
    state = pending_state(context, {140, 40})
    {buffer, _terminal} = render(state, 140, 40)
    {:ok, approve} = label_position(buffer, "[ Approve F8 ]")
    down = %Mouse{kind: "down", button: "left", x: approve.x, y: approve.y}
    {:noreply, pressed} = App.handle_event(down, state)
    {:noreply, selected} = App.handle_event(%{down | kind: "up", x: approve.x + 13}, pressed)
    assert selected.pending_approvals == state.pending_approvals
    refute selected.selection.active?
    assert Alto.TUI.Selection.text(selected.selection) == ""
    refute_receive {:alto_approval_decision, _, _}, 10
  end

  test "new approvals and the next queued request start at the top in both context layouts",
       context do
    for dimensions <- [{140, 40}, {80, 24}] do
      {width, height} = dimensions
      initial = pending_state(context, dimensions)

      initial = %{
        initial
        | pending_approvals: [],
          details_scroll: 500,
          selection: %{Alto.TUI.Selection.new() | active?: true}
      }

      request = %{
        id: "ls-request",
        tool: "run_command",
        arguments: %{"program" => "ls", "args" => ["-la"]},
        details: %{
          command: %{
            requested_program: "ls",
            executable: "/usr/bin/ls",
            args: ["-la"],
            cwd: context.root,
            timeout_ms: 30_000
          }
        }
      }

      {:noreply, shown} =
        App.handle_info({:alto_approval_request, "run", request, self()}, initial)

      assert shown.details_scroll == 0
      refute shown.selection.active?
      {buffer, _} = render(shown, width, height)
      assert buffer =~ "Run command"
      assert buffer =~ "ls -la"
      refute buffer =~ "%{"
      second = %{request | id: "pwd-request", arguments: %{"program" => "pwd"}, details: %{}}

      {:noreply, queued} =
        App.handle_info({:alto_approval_request, "run", second, self()}, %{
          shown
          | details_scroll: 2
        })

      assert queued.details_scroll == 2
      {:noreply, next} = App.handle_event(%ExRatatui.Event.Key{code: "f8"}, queued)
      assert_receive {:alto_approval_decision, "ls-request", :approve}
      assert next.details_scroll == 0
      {buffer, _} = render(next, width, height)
      assert buffer =~ "pwd"
      assert buffer =~ "Run command"
    end
  end

  test "context wheel and keyboard scrolling stop at content in both layouts", context do
    for {width, height} = dimensions <- [{140, 40}, {80, 24}] do
      state = pending_state(context, dimensions)
      [pending] = state.pending_approvals

      request = %{
        pending.request
        | details: %{preview: String.duplicate("line 猫\n", 100) <> "THE END"}
      }

      state = %{state | pending_approvals: [%{pending | request: request}], focus: :details}
      cap = View.details_bottom_scroll(state)
      assert cap > 0
      state = %{state | details_scroll: cap}
      {:noreply, state} = App.handle_event(%ExRatatui.Event.Key{code: "down"}, state)
      assert state.details_scroll == cap

      rect =
        View.context_overlay_rect(state, width, height) ||
          View.layout(state, width, height).details

      wheel = %Mouse{kind: "scroll_down", x: rect.x + 2, y: rect.y + 2}
      {:noreply, state} = App.handle_event(wheel, state)
      assert state.details_scroll == cap
      {buffer, _} = render(%{state | details_scroll: 65_000}, width, height)
      assert buffer =~ "THE END"
    end
  end

  test "approval selection autoscrolls wide panes and compact drawers without activating controls",
       context do
    for {width, height} = dimensions <- [{140, 40}, {80, 24}] do
      state = pending_state(context, dimensions)
      [pending] = state.pending_approvals

      request = %{
        pending.request
        | details: %{preview: Enum.map_join(0..99, "\n", &"line #{&1}")}
      }

      state = %{
        state
        | pending_approvals: [%{pending | request: request}],
          clipboard_write: fn _ -> :ok end
      }

      rect =
        View.context_overlay_rect(state, width, height) ||
          View.layout(state, width, height).details

      down = %Mouse{kind: "down", button: "left", x: rect.x + 1, y: rect.y + 2}
      {:noreply, state} = App.handle_event(down, state)
      assert state.selection.scroll != nil

      {:noreply, state} =
        App.handle_event(%{down | kind: "drag", x: width - 1, y: height - 1}, state)

      before = Alto.TUI.Selection.text(state.selection)
      token = state.selection.scroll.token
      {:noreply, state} = App.handle_info({:tui_selection_scroll, token}, state)
      assert state.details_scroll > 0
      assert String.starts_with?(Alto.TUI.Selection.text(state.selection), before)
      token = state.selection.scroll.token

      {:noreply, state} =
        App.handle_event(%{down | kind: "up", x: width - 1, y: height - 1}, state)

      assert {:noreply, ^state, render?: false} =
               App.handle_info({:tui_selection_scroll, token}, state)

      refute_receive {:alto_approval_decision, _, _}, 10

      {:noreply, copied} =
        App.handle_event(%ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"]}, state)

      assert copied.details_scroll == state.details_scroll
      assert copied.clipboard_text =~ "line 0"
      refute copied.clipboard_text =~ "Approve F8"
    end
  end

  test "disabled auto-open leaves a narrow approval queued behind the context indicator",
       context do
    config =
      context.config
      |> Keyword.put(:tui, approval_auto_open: false)
      |> Alto.Test.TUI.config()

    state = pending_state(context, {80, 24}, config)
    refute state.details_return_focus
    assert state.focus == :composer
    {buffer, _terminal} = render(state, 80, 24)
    assert buffer =~ "D:REQ"
  end

  defp pending_state(context, dimensions, config \\ nil) do
    assert {:ok, state} =
             State.new(config || context.config,
               project: context.root,
               path: context.catalog,
               credentials_path: Path.join(context.root, "credentials.json")
             )

    state = %{state | dimensions: dimensions, focus: :composer}
    request = %{id: "approval-1", tool: "record_mutation", arguments: %{}, details: %{}}

    assert {:noreply, prompted} =
             App.handle_info({:alto_approval_request, "run-1", request, self()}, state)

    prompted
  end

  defp render(state, width, height) do
    terminal = ExRatatui.init_test_terminal(width, height)
    assert :ok = ExRatatui.draw(terminal, View.widgets(state, %{width: width, height: height}))
    {ExRatatui.get_buffer_content(terminal), terminal}
  end

  defp label_position(buffer, label) do
    buffer
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {line, y} ->
      case :binary.match(line, label) do
        {byte_x, _length} ->
          {:ok, %{x: String.length(binary_part(line, 0, byte_x)), y: y}}

        :nomatch ->
          false
      end
    end)
  end

  defp click(mouse, state) do
    {:noreply, pressed} = App.handle_event(mouse, state)
    refute_receive {:alto_approval_decision, _, _}, 10
    App.handle_event(%{mouse | kind: "up"}, pressed)
  end

  defp click_at(%{x: x, y: y}, label),
    do: %Mouse{kind: "down", button: "left", x: x + div(String.length(label), 2), y: y}
end
