defmodule Alto.TUI.ViewportTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Viewport
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  test "cached chunks match native wrapping across boundaries, blanks and wide glyphs" do
    text =
      Enum.map_join(1..310, "\n", fn n ->
        if rem(n, 7) == 0, do: "", else: "#{n} α é 猫 👩‍💻 " <> String.duplicate("word ", rem(n, 12))
      end)

    for width <- [17, 40], offset <- [0, 126, 255, 380] do
      rect = %Rect{width: width, height: 14}
      original = [{%Paragraph{text: text, wrap: true, scroll: {offset, 0}}, rect}]
      native = ExRatatui.CellSession.new(width, 14)
      cached = ExRatatui.CellSession.new(width, 14)
      :ok = ExRatatui.CellSession.draw(native, original)
      :ok = ExRatatui.CellSession.draw(cached, Viewport.widgets(original))

      assert Enum.map(ExRatatui.CellSession.take_cells(native).cells, & &1.symbol) ==
               Enum.map(ExRatatui.CellSession.take_cells(cached).cells, & &1.symbol)

      ExRatatui.CellSession.close(native)
      ExRatatui.CellSession.close(cached)
    end
  end

  test "unwrapped viewports preserve alignment, horizontal scroll, Unicode and borders" do
    text = Enum.map_join(1..300, "\n", &"#{&1} 猫 é 👩‍💻 long plain text")
    rect = %Rect{width: 25, height: 9}

    for alignment <- [:left, :center, :right], offset <- [0, 127, 298], horizontal <- [0, 4] do
      original = [
        {%Paragraph{
           text: text,
           wrap: false,
           scroll: {offset, horizontal},
           alignment: alignment,
           block: %ExRatatui.Widgets.Block{title: "History", borders: [:all]}
         }, rect}
      ]

      native = ExRatatui.CellSession.new(25, 9)
      cached = ExRatatui.CellSession.new(25, 9)
      :ok = ExRatatui.CellSession.draw(native, original)
      :ok = ExRatatui.CellSession.draw(cached, Viewport.widgets(original))

      assert ExRatatui.CellSession.take_cells(native).cells ==
               ExRatatui.CellSession.take_cells(cached).cells

      ExRatatui.CellSession.close(native)
      ExRatatui.CellSession.close(cached)
    end
  end

  test "bottom uses native wrapping for blanks, Unicode, and long documents" do
    assert Viewport.bottom("", 20, 5) == 0
    assert Viewport.bottom("short", 20, 5) == 0
    assert Viewport.bottom("one\ntwo\nthree\n\n", 20, 2) == 1
    assert Viewport.bottom("猫猫猫猫猫猫", 4, 2) == 1
    assert Viewport.bottom("one two three four", 5, 2) == 2
    assert Viewport.bottom("one two three four", 30, 2) == 0
    assert Viewport.bottom("start" <> String.duplicate("\n", 300) <> "end", 20, 2) == 299
  end
end
