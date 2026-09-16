defmodule Alto.TUI.Scroll do
  @moduledoc "Exact, cached scroll limits using the terminal's own word wrapping."
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  def bottom(text, width, height, slot) do
    width = max(width, 1)
    key = {__MODULE__, slot}

    rows =
      case Process.get(key) do
        {^text, ^width, rows} ->
          rows

        _ ->
          rows = measure(String.trim_trailing(text), width)
          Process.put(key, {text, width, rows})
          rows
      end

    max(rows - max(height, 1), 0)
  end

  defp measure("", _width), do: 0

  defp measure(text, width) do
    # An absent private-use glyph marks the end even across pages of blank lines.
    marker =
      Enum.find_value(0xE000..0xF8FF, fn n ->
        glyph = <<n::utf8>>
        if not String.contains?(text, glyph), do: glyph
      end)

    terminal = ExRatatui.init_test_terminal(width, 256)
    count(terminal, text <> "\n" <> marker, marker, width, 0)
  end

  defp count(terminal, text, marker, width, offset) do
    :ok =
      ExRatatui.draw(terminal, [
        {%Paragraph{text: text, wrap: true, scroll: {offset, 0}},
         %Rect{width: width, height: 256}}
      ])

    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")

    case Enum.find_index(lines, &(&1 == marker)) do
      nil when offset < 65_279 -> count(terminal, text, marker, width, offset + 256)
      nil -> 65_535
      row -> offset + row
    end
  end
end
