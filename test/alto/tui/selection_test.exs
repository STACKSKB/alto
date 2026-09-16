defmodule Alto.TUI.SelectionTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.{Clipboard, Selection}
  alias ExRatatui.CellSession
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Clear, Paragraph}

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
    widgets = fn -> [{%Paragraph{text: "A猫👩‍💻éZ\nnext"}, %Rect{width: 12, height: 2}}] end
    selected = drag(widgets, {12, 2}, {7, 0}, {2, 0})
    assert Selection.text(selected) == "猫👩‍💻éZ"

    terminal = CellSession.new(12, 2)
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

    [{paragraph, _}] =
      Selection.widgets(selected, [{%Paragraph{text: "new text"}, %Rect{width: 10, height: 1}}])

    assert Enum.map_join(paragraph.text.lines, "\n", fn line ->
             Enum.map_join(line.spans, & &1.content)
           end) =~ "old text"

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
