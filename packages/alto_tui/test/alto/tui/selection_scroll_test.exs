defmodule Alto.TUI.SelectionScrollTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.Selection
  alias ExRatatui.Event.{Key, Mouse, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph}

  defp start(offset \\ 0, opts \\ []) do
    widgets = fn ->
      [
        {%Paragraph{text: "UI neighbor"}, %Rect{width: 12, height: 8}},
        {%Paragraph{
           text: Enum.map_join(0..29, "\n", &"line #{&1} 猫"),
           scroll: {offset, 0},
           block: %Block{borders: [:all]}
         }, %Rect{x: 12, width: 20, height: 8}}
      ]
    end

    {:handled, selection} =
      Selection.event(Selection.new(), mouse("down", 13, 3), {40, 10}, widgets, opts)

    selection
  end

  defp mouse(kind, x, y), do: %Mouse{kind: kind, button: "left", x: x, y: y}

  defp drag(selection, x, y) do
    {:handled, selection} =
      Selection.event(selection, mouse("drag", x, y), nil, fn -> flunk("rebuilt live view") end)

    selection
  end

  defp tick(selection) do
    {:scrolled, selection} = Selection.autoscroll(selection, selection.scroll.token)
    selection
  end

  defp release(selection) do
    {x, y} = selection.head
    {:handled, selection} = Selection.event(selection, mouse("up", x, y), nil, nil)
    selection
  end

  test "holding an edge scrolls without more motion and copies offscreen text inside its pane" do
    selection = start() |> drag(39, 6)
    token = selection.scroll.token
    assert_receive {:tui_selection_scroll, ^token}, 200
    selection = Enum.reduce(1..10, selection, fn _, s -> tick(s) end)
    assert Selection.scroll_position(selection) == {{13, 3}, 10}
    assert Selection.text(selection) == Enum.map_join(2..15, "\n", &"line #{&1} 猫")
    assert selection.anchor == {13, -7}

    assert Enum.all?(selection.highlight, fn {_, rect} ->
             rect.x >= 13 and rect.x + rect.width <= 31
           end)

    token = selection.scroll.token
    selection = release(selection)
    assert {:idle, ^selection} = Selection.autoscroll(selection, token)

    assert {:copy, text, _} =
             Selection.event(selection, %Key{code: "c", modifiers: ["ctrl"]}, nil, nil)

    refute text =~ "UI"
    assert text =~ "line 2 猫"
    assert text =~ "line 15 猫"
  end

  test "reversing past the anchor selects earlier rows; bounds stop the timer" do
    selection = start(8) |> drag(30, 6) |> tick() |> tick()
    selection = drag(selection, 13, -10)
    selection = Enum.reduce(1..10, selection, fn _, s -> tick(s) end)
    assert selection.scroll.offset == 0
    assert Selection.text(selection) == Enum.map_join(0..9, "\n", &"line #{&1} 猫") <> "\nl"
    assert {:idle, stopped} = Selection.autoscroll(selection, selection.scroll.token)
    assert stopped.scroll.token == nil
    selection = drag(stopped, 30, 20)
    selection = Enum.reduce(1..24, selection, fn _, s -> tick(s) end)
    assert selection.scroll.offset == 24
    assert {:idle, stopped} = Selection.autoscroll(selection, selection.scroll.token)
    assert stopped.scroll.token == nil
    assert Selection.text(stopped) == Enum.map_join(10..29, "\n", &"line #{&1} 猫")
  end

  test "moving inside, release, escape and resize invalidate pending timers" do
    for action <- [:inside, :release, :escape, :resize, :focus_lost] do
      selection = start() |> drag(30, 6)
      token = selection.scroll.token

      next =
        case action do
          :focus_lost ->
            elem(Selection.event(selection, %ExRatatui.Event.FocusLost{}, nil, nil), 1)

          :inside ->
            drag(selection, 30, 4)

          :release ->
            release(selection)

          :escape ->
            elem(Selection.event(selection, %Key{code: "esc"}, nil, nil), 1)

          :resize ->
            elem(Selection.event(selection, %Resize{width: 50, height: 20}, nil, nil), 1)
        end

      assert {:idle, ^next} = Selection.autoscroll(next, token)
    end
  end

  test "top and bottom scroll at the same speed despite unequal space outside the pane" do
    up = start(10) |> drag(13, 0) |> tick() |> release()
    down = start(10) |> drag(30, 100) |> tick() |> release()
    assert 10 - up.scroll.offset == down.scroll.offset - 10
    assert down.scroll.offset == 11
  end

  test "wrapped rows retain exact rendered boundaries across autoscroll" do
    text = Enum.map_join(0..19, "\n", &"#{&1}: 猫 words that wrap")
    widgets = fn -> [{%Paragraph{text: text, wrap: true}, %Rect{width: 10, height: 4}}] end

    {:handled, selection} =
      Selection.event(Selection.new(), mouse("down", 0, 1), {10, 4}, widgets)

    selection = drag(selection, 9, 3)
    selection = Enum.reduce(1..12, selection, fn _, s -> tick(s) end)
    terminal = ExRatatui.init_test_terminal(10, 16)
    ExRatatui.draw(terminal, [{%Paragraph{text: text, wrap: true}, %Rect{width: 10, height: 16}}])

    rendered =
      ExRatatui.get_buffer_content(terminal)
      |> String.split("\n")
      |> Enum.slice(1, 15)
      |> Enum.map_join("\n", &String.trim_trailing(String.replace(&1, "猫 ", "猫")))

    assert Selection.text(selection) == rendered
    release(selection)
  end

  test "wheel while holding extends selection and a client can disable scrolling" do
    selection = start() |> drag(30, 4)
    {:handled, selection} = Selection.event(selection, mouse("scroll_down", 30, 4), nil, nil)
    assert selection.scroll.offset == 3
    assert Selection.text(selection) == Enum.map_join(2..6, "\n", &"line #{&1} 猫")
    selection = start(0, scroll_limit: fn _ -> nil end) |> drag(30, 6)
    assert {:idle, stopped} = Selection.autoscroll(selection, selection.scroll.token)
    assert stopped.scroll.offset == 0
  end
end
