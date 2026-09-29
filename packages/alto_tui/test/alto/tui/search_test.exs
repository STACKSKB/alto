defmodule Alto.TUI.SearchTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.{App, Search, State, View}
  alias ExRatatui.Event.{Key, Paste, Resize}

  setup do
    root = Path.join(System.tmp_dir!(), "alto-search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, state} =
      State.new(Alto.Test.TUI.config(),
        project: root,
        path: Path.join(root, "catalog.json"),
        credentials_path: Path.join(root, "credentials.json")
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{state: state, root: root}
  end

  test "literal case-insensitive occurrences include coding/tool details without regex expansion" do
    entries = [
      %{kind: :user, text: "Needle NEEDLE needle"},
      %{kind: :assistant, text: "a.b A.B axb [x] C++ Café CAFÉ"},
      %{kind: :tool, text: "edit_file", detail: "- old\n+ Needle"}
    ]

    assert length(Search.find(entries, "needle")) == 4
    assert Enum.map(Search.find(entries, "a.b"), & &1.hit) == ["a.b", "A.B"]
    assert length(Search.find(entries, "[x]")) == 1
    assert length(Search.find(entries, "c++")) == 1
    assert Enum.map(Search.find(entries, "café"), & &1.hit) == ["Café", "CAFÉ"]
    assert Search.find(entries, "") == []
    assert Search.find(entries, "need le") == []
  end

  test "navigation wraps, jumps into long entries, highlights soft wraps, and survives resizing",
       %{state: state} do
    text =
      String.duplicate("filler\n", 45) <>
        "alpha beta gamma\n" <> String.duplicate("tail\n", 40) <> "ALPHA BETA GAMMA"

    state =
      state
      |> State.put_entries(nil, [%{kind: :tool, text: text}])
      |> Search.open()
      |> Search.paste("alpha beta gamma")

    for width <- [12, 80] do
      data = Search.projection(state, width)
      assert length(data.matches) == 2
      assert hd(data.matches).row >= 45
      assert hd(data.matches).ranges != []
      highlighted = Search.highlighted(state, width)

      hit =
        for line <- highlighted.lines,
            span <- line.spans,
            span.style && span.style.bg == :light_cyan,
            into: "",
            do: span.content

      assert String.replace(hit, " ", "") == "alphabetagamma"
    end

    first = View.reveal_search(state)
    next = first |> Search.move(1) |> View.reveal_search()
    assert next.transcript_scroll > first.transcript_scroll
    assert Search.count(next) == "2/2"
    assert Search.count(Search.move(next, 1)) == "1/2"
    assert Search.count(Search.move(first, -1)) == "2/2"
    {:noreply, resized} = App.handle_event(%Resize{width: 44, height: 14}, next)
    assert Search.count(resized) == "2/2"
    assert resized.transcript_scroll > 45
  end

  test "hard newlines cannot steal the position of a later exact substring", %{state: state} do
    state =
      state
      |> State.put_entries(nil, [%{kind: :user, text: "ab\ncd\n\nABCD"}])
      |> Search.open()
      |> Search.paste("abcd")

    data = Search.projection(state, 40)
    assert [%{row: 3, ranges: [{3, 0, 4}]}] = data.matches
  end

  test "styled Markdown is highlighted across spans and assistant labels are not search hits", %{
    state: state
  } do
    state =
      state
      |> State.put_entries(nil, [%{kind: :assistant, text: "**Alto** and `alto`"}])
      |> Search.open()
      |> Search.paste("alto")

    data = Search.projection(state, 40)
    assert length(data.matches) == 2
    assert Enum.all?(data.matches, &(&1.row > 0 and &1.ranges != []))
    text = Search.highlighted(state, 40)
    refute Enum.any?(hd(text.lines).spans, &(&1.style && &1.style.bg == :light_cyan))
    assert length(Search.find([%{kind: :assistant, text: "unrelated"}], "alto")) == 0
  end

  test "Ctrl+F protects the draft, shows controls without context, and routes keyboard and mouse results",
       %{state: state} do
    state =
      State.put_entries(%{state | dimensions: {50, 16}}, nil, [
        %{kind: :user, text: "needle"},
        %{kind: :tool, text: "NEEDLE"}
      ])

    ExRatatui.textarea_insert_str(state.textarea, "unsent draft")
    {:noreply, state} = App.handle_event(%Key{code: "f", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Paste{content: "needle"}, state)
    assert Search.count(state) == "1/2"
    assert state.runs == %{}
    assert screen(state, 50, 16) =~ "[Prev][Next] 1/2"
    assert View.layout(state, 50, 16).details == nil
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    assert Search.count(state) == "2/2"
    {:noreply, state} = App.handle_event(%Key{code: "enter", modifiers: ["shift"]}, state)
    assert Search.count(state) == "1/2"
    {:noreply, details} = App.handle_event(%Key{code: "tab"}, state)
    assert details.focus == :details
    assert screen(details, 50, 16) =~ "search results"
    assert View.hit_target(details, 50, 16, 2, 2) == {:search_result, 1}

    {:noreply, clicked} =
      App.handle_event(%ExRatatui.Event.Mouse{kind: "down", button: "left", x: 2, y: 2}, %{
        details
        | dimensions: {50, 16}
      })

    # Selection routes ordinary clicks on mouse-up.
    {:noreply, clicked} =
      App.handle_event(%ExRatatui.Event.Mouse{kind: "up", button: "left", x: 2, y: 2}, clicked)

    assert clicked.focus == :transcript
    assert clicked.details_return_focus == nil
    assert View.context_overlay_rect(clicked, 50, 16) == nil
    assert Search.count(clicked) == "2/2"
    assert View.hit_target(clicked, 50, 16, 1, 15) == :search_prev
    {:noreply, closed} = App.handle_event(%Key{code: "esc"}, clicked)
    assert closed.search == nil
    assert ExRatatui.textarea_get_value(closed.textarea) == "unsent draft"
    assert closed.runs == %{}
  end

  test "query editing, no matches, streaming changes and task switches do not retain stale hits",
       %{state: state} do
    state =
      state
      |> State.put_entries(nil, [%{kind: :assistant, text: "needle"}])
      |> Search.open()
      |> Search.paste("needl")

    {:noreply, state} = App.handle_event(%Key{code: "e"}, state)
    assert Search.count(state) == "1/1"
    state = State.append_assistant_delta(state, nil, " NEEDLE")
    assert Search.count(state) == "1/2"
    {:noreply, state} = App.handle_event(%Key{code: "left"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "x"}, state)
    assert Search.query(state) == "needlxe"
    assert Search.count(state) == "0/0"
    drawer = State.open_details_drawer(%{state | dimensions: {60, 18}})
    assert screen(drawer, 60, 18) =~ "No matches"
    {:noreply, state} = App.handle_event(%Key{code: "u", modifiers: ["ctrl"]}, state)
    assert Search.query(state) == ""
    assert State.new_task(state).search == nil
    assert State.select_project(state, state.selected_project_id).search == nil
  end

  test "long result lists keep selection and mouse hit rows aligned", %{state: state} do
    entries = Enum.map(1..35, fn i -> %{kind: :user, text: "hit #{i}"} end)

    state =
      state
      |> State.put_entries(nil, entries)
      |> Search.open()
      |> Search.paste("hit")
      |> Search.select(34)

    state = State.open_details_drawer(%{state | dimensions: {50, 16}})
    buffer = screen(state, 50, 16)
    assert buffer =~ "35/35"
    assert buffer =~ "35 · user"
    assert View.hit_target(state, 50, 16, 2, 13) == {:search_result, 34}
  end

  test "wide search uses the side panel and restores hidden context and prior focus", %{
    state: state
  } do
    state = %{state | dimensions: {150, 36}, details_visible?: false, focus: :transcript}
    state = State.put_entries(state, nil, [%{kind: :user, text: "needle"}])
    ExRatatui.textarea_insert_str(state.textarea, "preserved draft")
    {:noreply, searching} = App.handle_event(%Key{code: "f", modifiers: ["ctrl"]}, state)
    {:noreply, searching} = App.handle_event(%Paste{content: "needle"}, searching)
    layout = View.layout(searching, 150, 36)
    assert layout.details
    assert layout.transcript.x + layout.transcript.width == layout.details.x
    assert layout.composer.x + layout.composer.width == layout.details.x
    assert screen(searching, 150, 36) =~ "search results"
    assert screen(searching, 150, 36) =~ "preserved draft"
    {:noreply, results} = App.handle_event(%Key{code: "tab"}, searching)
    assert results.focus == :details
    assert results.details_visible?
    {:noreply, transcript} = App.handle_event(%Key{code: "back_tab"}, results)
    assert transcript.focus == :transcript
    assert transcript.details_visible?
    {:noreply, closed} = App.handle_event(%Key{code: "esc"}, transcript)
    assert closed.search == nil
    assert closed.focus == :transcript
    refute closed.details_visible?
    refute View.layout(closed, 150, 36).details
    assert ExRatatui.textarea_get_value(closed.textarea) == "preserved draft"
  end

  test "narrow search Tab opens and closes a drawer and Escape restores focus without cancelling",
       %{state: state} do
    original = %{state | dimensions: {80, 24}, focus: :transcript, runs: %{run: %{task_id: nil}}}
    {:noreply, searching} = App.handle_event(%Key{code: "f", modifiers: ["ctrl"]}, original)
    assert View.context_overlay_rect(searching, 80, 24) == nil
    {:noreply, drawer} = App.handle_event(%Key{code: "tab"}, searching)
    assert drawer.focus == :details
    rect = View.context_overlay_rect(drawer, 80, 24)
    assert rect.x > 0
    assert rect.width < 80
    assert screen(drawer, 80, 24) =~ "search results"
    assert View.hit_target(drawer, 80, 24, 1, 23) == :search_prev
    {:noreply, transcript} = App.handle_event(%Key{code: "tab"}, drawer)
    assert transcript.focus == :transcript
    assert transcript.details_return_focus == nil
    assert transcript.search != nil
    {:noreply, drawer} = App.handle_event(%Key{code: "tab"}, transcript)
    {:noreply, closed} = App.handle_event(%Key{code: "esc"}, drawer)
    assert closed.search == nil
    assert closed.details_return_focus == nil
    assert closed.focus == :transcript
    assert closed.runs == original.runs
  end

  test "approvals interrupt search without stealing focus when automatic opening is disabled", %{
    state: state
  } do
    state = %{state | dimensions: {140, 40}, approval_auto_open?: false, focus: :transcript}

    pending = %{
      request: %{
        id: "approval",
        tool: "write_file",
        arguments: %{path: "review.txt", content: "review me"}
      },
      respond: fn decision -> send(self(), {:decision, decision}) end
    }

    searching = state |> Search.open() |> Search.paste("needle")
    shown = App.show_pending_approval(searching, pending, "approval required")
    assert shown.search == nil
    assert shown.focus == :transcript
    assert screen(shown, 140, 40) =~ "approval required"
    assert screen(shown, 140, 40) =~ "Approve F8"

    # Opening search while a request is already pending cannot replace its controls.
    resumed = shown |> Search.open() |> Search.paste("needle")
    buffer = screen(resumed, 140, 40)
    assert buffer =~ "approval required"
    assert buffer =~ "Approve F8"
    refute buffer =~ "search results"

    assert Enum.any?(0..39, fn y ->
             Enum.any?(0..139, fn x ->
               View.hit_target(resumed, 140, 40, x, y) == {:approval, :approve}
             end)
           end)

    {:noreply, decided} = App.handle_event(%Key{code: "f8"}, resumed)
    assert_receive {:decision, :approve}
    assert decided.pending_approvals == []

    narrow = %{state | dimensions: {80, 24}}
    shown = App.show_pending_approval(Search.open(narrow), pending, "approval required")
    assert shown.search == nil
    assert shown.focus == :transcript
    assert shown.details_return_focus == nil

    drawer = State.open_details_drawer(shown)
    resumed = Search.open(drawer)
    assert resumed.details_return_focus == drawer.details_return_focus
    assert View.context_overlay_rect(resumed, 80, 24) != nil
    assert screen(resumed, 80, 24) =~ "Approve F8"
    refute screen(resumed, 80, 24) =~ "search results"
  end

  test "automatic approval presentation closes search instead of hiding the approval", %{
    state: state
  } do
    pending = %{request: %{id: "approval"}, respond: fn _ -> flunk("search must not approve") end}
    state = state |> Search.open() |> Search.paste("text")
    shown = App.show_pending_approval(state, pending, "approval required")
    assert shown.search == nil
    assert shown.focus == :details
    assert shown.pending_approvals == [pending]
  end

  test "manual approval preserves context while background cleanup closes an automatic drawer", %{
    state: state
  } do
    pending = %{local_id: "run", request: %{id: "approval"}, respond: fn _ -> :ok end}
    state = %{state | dimensions: {80, 24}, focus: :transcript}

    for {manual?, resolve} <- [
          {true,
           fn state ->
             {:noreply, next} = App.handle_event(%Key{code: "f8"}, state)
             next
           end},
          {false, &App.drop_run(&1, "run")}
        ] do
      searching =
        state |> App.show_pending_approval(pending, "approval required") |> Search.open()

      assert searching.details_drawer_auto_opened?
      closed = searching |> resolve.() |> Search.close()
      assert closed.pending_approvals == []
      assert closed.search == nil
      refute closed.details_drawer_auto_opened?

      if manual? do
        assert closed.details_return_focus == :transcript
        assert closed.focus == :details
        assert View.context_overlay_rect(closed, 80, 24) != nil
      else
        assert closed.details_return_focus == nil
        assert closed.focus == :transcript
        assert View.context_overlay_rect(closed, 80, 24) == nil
      end
    end
  end

  defp screen(state, width, height) do
    terminal = ExRatatui.init_test_terminal(width, height)

    ExRatatui.draw(
      terminal,
      App.render(%{state | dimensions: {width, height}}, %{width: width, height: height})
    )

    ExRatatui.get_buffer_content(terminal)
  end

  test "dense search is capped before excerpt allocation and clears on close", %{state: state} do
    state =
      state
      |> State.put_entries(nil, [%{kind: :assistant, text: String.duplicate("a ", 10_000)}])
      |> Search.open()
      |> Search.paste("a")

    matches = Search.matches(state)
    assert length(matches) == 1000
    assert Search.count(state) == "1/1000+"
    assert hd(matches).start == 0
    assert List.last(matches).start == 1998
    refute Map.has_key?(hd(matches), :before)
    refute Map.has_key?(hd(matches), :source)
    assert Enum.any?(Alto.TUI.Cache.stats().items, fn {{{mod, _}, _}, _} -> mod == Search end)
    Search.close(state)
    refute Enum.any?(Alto.TUI.Cache.stats().items, fn {{{mod, _}, _}, _} -> mod == Search end)
  end
end
