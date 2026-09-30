defmodule Alto.TUI.ViewportTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Viewport
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  test "scratch resize releases the old native grid without closing other owners" do
    original = Viewport.test_terminal(:markdown_metrics, 20, 5)
    selection = Viewport.test_terminal(:selection, 20, 5)
    assert Viewport.test_terminal(:markdown_metrics, 20, 5) == original

    replacement = Viewport.test_terminal(:markdown_metrics, 30, 8)
    assert {:error, "terminal not initialized"} = ExRatatui.get_buffer_content(original)
    assert ExRatatui.get_buffer_content(selection) == ""

    assert :ok =
             ExRatatui.draw(replacement, [
               {%Paragraph{text: "resized 猫"}, %Rect{width: 30, height: 8}}
             ])

    assert ExRatatui.get_buffer_content(replacement) == "resized 猫"
  end

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

  test "visible windows preserve native cells and absolute history size without blank padding" do
    alias Alto.TUI.Transcript

    entries =
      [%{kind: :user, text: "start"}] ++
        for n <- 1..30 do
          %{kind: :assistant, text: "## #{n} 猫\n\n```elixir\nvalue = #{n}\n\n:ok\n```"}
        end

    full = Transcript.render(entries, 38)
    index = Transcript.index(entries, 38)
    rect = %Rect{width: 40, height: 22}

    for offset <- [0, 37, index.rows - 20] do
      window = Transcript.viewport(entries, 38, offset, 20)
      assert length(window.lines) == 20
      assert window.offset == offset
      assert window.rows == index.rows
      assert Viewport.bottom(window, 38, 20) == Viewport.bottom(full, 38, 20)
      block = %ExRatatui.Widgets.Block{title: "History", borders: [:all]}
      original = [{%Paragraph{text: full, wrap: false, scroll: {offset, 0}, block: block}, rect}]
      visible = [{%Paragraph{text: window, wrap: false, scroll: {offset, 0}, block: block}, rect}]
      native = ExRatatui.CellSession.new(40, 22)
      candidate = ExRatatui.CellSession.new(40, 22)
      :ok = ExRatatui.CellSession.draw(native, original)
      :ok = ExRatatui.CellSession.draw(candidate, Viewport.widgets(visible))

      assert ExRatatui.CellSession.take_cells(candidate).cells ==
               ExRatatui.CellSession.take_cells(native).cells

      ExRatatui.CellSession.close(native)
      ExRatatui.CellSession.close(candidate)
    end
  end
end
