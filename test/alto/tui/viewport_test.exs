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
end
