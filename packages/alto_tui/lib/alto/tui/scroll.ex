defmodule Alto.TUI.Scroll do
  @moduledoc "Exact, cached scroll limits using the terminal's own word wrapping."

  def bottom(%ExRatatui.Text{} = text, width, height, _slot),
    do: Alto.TUI.Viewport.bottom(text, width, height)

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

  defp measure(text, width), do: tuple_size(Alto.TUI.Viewport.rows(text, width))
end
