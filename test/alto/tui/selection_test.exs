defmodule Alto.TUI.SelectionTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.{Clipboard, Selection}
  alias ExRatatui.CellSession
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Clear, Paragraph, Popup}

  test "selects final visible cells anywhere, including borders, overlays and status" do
    widgets = fn ->
      [
        {%Paragraph{text: "title\nsecret hidden\nsidebar | answer\nstatus"},
         %Rect{width: 30, height: 4}},
        {%Clear{}, %Rect{y: 1, width: 30, height: 1}},
        {%Paragraph{text: "•••• popup"}, %Rect{y: 1, width: 30, height: 1}}
      ]
    end

    {:handled, selected} =
      Selection.event(
        Selection.new(),
        %Key{code: "A", modifiers: ["shift", "ctrl"]},
        {30, 4},
        widgets
      )

    assert Selection.text(selected) == "title\n•••• popup\nsidebar | answer\nstatus"
    refute Selection.text(selected) =~ "secret"

    {:copy, copied, cleared} =
      Selection.event(selected, %Key{code: "c", modifiers: ["ctrl"]}, {30, 4}, widgets)

    assert copied =~ "status"
    refute cleared.active?
  end

  test "reverse drags and Unicode use display cells without copying wide-cell filler" do
    widgets = fn -> [{%Paragraph{text: "A猫👩‍💻éZ\nnext"}, %Rect{width: 12, height: 3}}] end
    selected = drag(widgets, {12, 3}, {7, 0}, {2, 0})
    assert Selection.text(selected) == "猫👩‍💻éZ"

    terminal = CellSession.new(12, 3)
    on_exit(fn -> CellSession.close(terminal) end)
    :ok = CellSession.draw(terminal, Selection.widgets(selected, []))
    cells = CellSession.take_cells(terminal).cells
    assert Enum.find(cells, &(&1.symbol == "猫")).bg == :light_blue
    assert Enum.find(cells, &(&1.symbol == "Z")).col == 6
    assert Enum.find(cells, &(&1.symbol == "n")).row == 1
  end

  test "selection is frozen while new output arrives; resize, paste and Escape clear it" do
    widgets = fn -> [{%Paragraph{text: "old text"}, %Rect{width: 10, height: 1}}] end
    selected = drag(widgets, {10, 1}, {0, 0}, {7, 0})

    [{paragraph, _} | _] =
      Selection.widgets(selected, [{%Paragraph{text: "new text"}, %Rect{width: 10, height: 1}}])

    assert paragraph.text == "old text"

    assert {:handled, %{active?: false}} =
             Selection.event(selected, %Key{code: "esc"}, {10, 1}, widgets)

    assert {:pass, %{active?: false}} =
             Selection.event(selected, %Resize{width: 5, height: 1}, {10, 1}, widgets)

    assert {:pass, %{active?: false}} =
             Selection.event(selected, %Paste{content: "new"}, {10, 1}, widgets)
  end

  test "click actions occur only on release and a drag never becomes a click" do
    widgets = fn -> [{%Paragraph{text: "Approve"}, %Rect{width: 10, height: 1}}] end
    down = %Mouse{kind: "down", button: "left", x: 0, y: 0}
    {:handled, pressed} = Selection.event(Selection.new(), down, {10, 1}, widgets)
    assert {:click, ^down, _} = Selection.event(pressed, %{down | kind: "up"}, {10, 1}, widgets)
    {:handled, dragged} = Selection.event(pressed, %{down | kind: "drag", x: 5}, {10, 1}, widgets)

    assert {:handled, %{active?: true}} =
             Selection.event(dragged, %{down | kind: "up"}, {10, 1}, widgets)
  end

  test "copy release is ignored and plain Ctrl+C without selection remains available to the client" do
    selected = %{Selection.new() | active?: true}

    assert {:pass, ^selected} =
             Selection.event(
               selected,
               %Key{kind: "release", code: "c", modifiers: ["ctrl"]},
               {10, 1},
               nil
             )

    assert {:pass, _} =
             Selection.event(Selection.new(), %Key{code: "c", modifiers: ["ctrl"]}, {10, 1}, nil)

    assert {:handled, _} =
             Selection.event(
               Selection.new(),
               %Key{code: "c", modifiers: ["ctrl", "shift"]},
               {10, 1},
               nil
             )
  end

  test "clipboard payload is base64 and cannot inject terminal escapes" do
    text = "hello\n猫\e]52;c;bad\a"
    assert Clipboard.sequence(text) == "\e]52;c;" <> Base.encode64(text) <> "\a"
  end

  test "a multirow drag stays inside its box even when the mouse crosses adjacent panes" do
    widgets = fn ->
      [
        {%Paragraph{text: "left text", block: %Block{title: "left", borders: [:all]}},
         %Rect{width: 12, height: 6}},
        {%Paragraph{
           text: "first\nsecond\nthird",
           block: %Block{title: "center", borders: [:all]}
         }, %Rect{x: 12, width: 12, height: 6}},
        {%Paragraph{text: "right text", block: %Block{title: "right", borders: [:all]}},
         %Rect{x: 24, width: 12, height: 6}}
      ]
    end

    selected = drag(widgets, {36, 7}, {13, 1}, {35, 3})
    assert Selection.text(selected) == "first\nsecond\nthird"
    reverse = drag(widgets, {36, 7}, {22, 3}, {0, 1})
    assert Selection.text(reverse) == "first\nsecond\nthird"
    cells = render_cells(Selection.widgets(selected, []), {36, 7})

    assert Enum.filter(cells, &(&1.bg == :light_blue and &1.row < 6))
           |> Enum.all?(&(&1.col in 13..22 and &1.row in 1..3))
  end

  test "popups own their content and remain excluded from selections behind them" do
    widgets = fn ->
      [
        {%Paragraph{text: "background\nbackground\nbackground\nbackground"},
         %Rect{width: 40, height: 6}},
        {%Popup{
           content: %Paragraph{text: "popup\nonly"},
           block: %Block{borders: [:all]},
           fixed_width: 12,
           fixed_height: 4
         }, %Rect{width: 40, height: 6}}
      ]
    end

    assert Selection.text(drag(widgets, {40, 6}, {15, 2}, {39, 5})) == "popup\nonly"
    refute Selection.text(drag(widgets, {40, 6}, {0, 0}, {39, 5})) =~ "popup"
  end

  test "selection adds no toolbar; right-click opens an unframed menu with a muted shortcut" do
    widgets = fn -> [{%Paragraph{text: "copy me"}, %Rect{width: 60, height: 6}}] end
    selected = drag(widgets, {60, 6}, {0, 0}, {6, 0})
    cells = render_cells(Selection.widgets(selected, []), {60, 6})
    assert Enum.filter(cells, &(&1.row > 0)) |> Enum.all?(&(&1.symbol == " "))

    {:handled, menu} =
      Selection.event(
        selected,
        %Mouse{kind: "down", button: "right", x: 59, y: 5},
        {60, 6},
        widgets
      )

    assert menu.menu.x + menu.menu.width <= 60
    assert menu.menu.y + menu.menu.height <= 6
    assert menu.menu.height == 1
    rendered = Selection.widgets(menu, [])
    {paragraph, _} = List.last(rendered)
    assert paragraph.block == nil

    assert [%{content: " Copy         "}, %{content: "Ctrl+C  ", style: shortcut}] =
             paragraph.text.spans

    assert :dim in shortcut.modifiers
    assert shortcut.fg == {:rgb, 155, 162, 174}
    assert {:copy, "copy me", _} = Selection.event(menu, %Key{code: "enter"}, {60, 6}, widgets)
    down = %Mouse{kind: "down", button: "left", x: menu.menu.x + 2, y: menu.menu.y}
    {:handled, pressed} = Selection.event(menu, down, {60, 6}, widgets)

    assert {:copy, "copy me", _} =
             Selection.event(pressed, %{down | kind: "up"}, {60, 6}, widgets)

    {:handled, dismissed} = Selection.event(menu, %Key{code: "esc"}, {60, 6}, widgets)
    assert dismissed.active?
    assert dismissed.menu == nil
  end

  test "drag motion and repaint reuse the frame without rebuilding the live view" do
    widgets = fn ->
      send(self(), :built)
      [{%Paragraph{text: String.duplicate("content\n", 60)}, %Rect{width: 240, height: 70}}]
    end

    down = %Mouse{kind: "down", button: "left", x: 0, y: 0}
    {:handled, pressed} = Selection.event(Selection.new(), down, {240, 70}, widgets)
    assert_receive :built
    Selection.widgets(pressed, fn -> flunk("mouse-down rebuilt the live view") end)

    for row <- 1..60 do
      {:handled, selected} =
        Selection.event(pressed, %{down | kind: "drag", x: 100, y: row}, {240, 70}, widgets)

      frozen = Selection.widgets(selected, fn -> flunk("drag rebuilt the live view") end)
      [{background, _} | _] = frozen
      assert background.text == String.duplicate("content\n", 60)
      assert length(frozen) <= 62
    end

    refute_receive :built, 0
  end

  test "freezes mutable inputs without exporting every screen cell" do
    input = ExRatatui.text_input_new()
    ExRatatui.text_input_set_value(input, "original")

    widgets = fn ->
      [{%ExRatatui.Widgets.TextInput{state: input}, %Rect{width: 30, height: 1}}]
    end

    selected = drag(widgets, {30, 1}, {0, 0}, {7, 0})
    ExRatatui.text_input_set_value(input, "changed")
    assert Selection.text(selected) == "original"
    cells = render_cells(Selection.widgets(selected, []), {30, 1})
    assert Enum.map_join(cells, & &1.symbol) =~ "original"
    refute Enum.map_join(cells, & &1.symbol) =~ "changed"
    selected = drag(widgets, {30, 1}, {0, 0}, {6, 0})
    assert Selection.text(selected) == "changed"
  end

  test "non-content controls neither capture a frame nor activate when dragged; Alt opts in" do
    widgets = fn ->
      send(self(), :captured)
      [{%Paragraph{text: "Button"}, %Rect{width: 20, height: 3}}]
    end

    down = %Mouse{kind: "down", button: "left", x: 0, y: 0}
    opts = [content: fn -> [] end]
    {:handled, pressed} = Selection.event(Selection.new(), down, {20, 3}, widgets, opts)
    assert pressed.snapshot == nil

    assert {:click, ^down, _} =
             Selection.event(pressed, %{down | kind: "up"}, {20, 3}, widgets, opts)

    {:handled, moved} =
      Selection.event(pressed, %{down | kind: "drag", x: 3}, {20, 3}, widgets, opts)

    assert {:handled, %{active?: false}} =
             Selection.event(moved, %{down | kind: "up"}, {20, 3}, widgets, opts)

    refute_receive :captured, 0

    {:handled, pressed} =
      Selection.event(Selection.new(), %{down | modifiers: ["alt"]}, {20, 3}, widgets, opts)

    {:handled, selected} =
      Selection.event(pressed, %{down | kind: "up", x: 5}, {20, 3}, widgets, opts)

    assert Selection.text(selected) == "Button"
  end

  test "dragging outside a one-cell region cannot activate its click action" do
    widgets = fn -> [{%Paragraph{text: "X"}, %Rect{width: 1, height: 1}}] end
    assert drag(widgets, {20, 3}, {0, 0}, {19, 0}).active?
  end

  test "a coalesced drag returning to its anchor never becomes a button click" do
    widgets = fn -> [{%Paragraph{text: "Approve"}, %Rect{width: 20, height: 2}}] end
    down = %Mouse{kind: "down", button: "left", x: 0, y: 0}

    for content <- [fn -> [] end, fn -> :all end] do
      opts = [content: content]
      {:handled, pressed} = Selection.event(Selection.new(), down, {20, 2}, widgets, opts)

      {:handled, dragged} =
        Selection.event(pressed, %{down | kind: "drag"}, {20, 2}, widgets, opts)

      assert {:handled, _} =
               Selection.event(dragged, %{down | kind: "up"}, {20, 2}, widgets, opts)
    end
  end

  test "large selections shrink and reverse without stale highlight or broken Unicode boundaries" do
    widgets = fn ->
      [{%Paragraph{text: String.duplicate("A猫👩‍💻éZ\n", 18)}, %Rect{width: 40, height: 20}}]
    end

    down = %Mouse{kind: "down", button: "left", x: 1, y: 8}
    {:handled, initial} = Selection.event(Selection.new(), down, {40, 20}, widgets)

    Enum.reduce([{38, 18}, {3, 2}, {7, 8}, {2, 8}, {38, 18}, {0, 0}], initial, fn {x, y}, state ->
      {:handled, selected} =
        Selection.event(state, %{down | kind: "drag", x: x, y: y}, {40, 20}, widgets)

      cells = render_cells(Selection.widgets(selected, []), {40, 20})
      highlighted = Enum.filter(cells, &(&1.bg == :light_blue))
      assert Enum.all?(highlighted, &(&1.row in min(y, 8)..max(y, 8)))
      assert Enum.filter(cells, &(&1.symbol == "Z")) |> Enum.all?(&(&1.col == 6))

      if y == 8 do
        assert Selection.text(selected) == if(x == 2, do: "猫", else: "猫👩‍💻éZ")
      end

      selected
    end)
  end

  defp render_cells(widgets, {width, height}) do
    terminal = CellSession.new(width, height)

    try do
      :ok = CellSession.draw(terminal, widgets)
      CellSession.take_cells(terminal).cells
    after
      CellSession.close(terminal)
    end
  end

  defp drag(widgets, dimensions, {ax, ay}, {hx, hy}) do
    {:handled, pressed} =
      Selection.event(
        Selection.new(),
        %Mouse{kind: "down", button: "left", x: ax, y: ay},
        dimensions,
        widgets
      )

    {:handled, selected} =
      Selection.event(
        pressed,
        %Mouse{kind: "drag", button: "left", x: hx, y: hy},
        dimensions,
        widgets
      )

    {:handled, released} =
      Selection.event(
        selected,
        %Mouse{kind: "up", button: "left", x: hx, y: hy},
        dimensions,
        widgets
      )

    released
  end
end
