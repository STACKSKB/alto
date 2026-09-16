defmodule Alto.TUI.SelectionRegions do
  @moduledoc false
  alias Alto.TUI.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Popup}

  # Follow paint order, using the same rectangles as the renderer. Borders are
  # independently selectable; a drag inside a box never includes its chrome.
  def at(widgets, {x, y}, {width, height}) do
    regions = Enum.flat_map(widgets, &regions/1) |> Enum.reverse()
    {covered, rest} = Enum.split_while(regions, &(not Layout.contains?(&1, x, y)))
    rect = List.first(rest) || %Rect{x: x, y: y, width: 1, height: 1}
    right = min(rect.x + rect.width, width)
    bottom = min(rect.y + rect.height, height)
    rect = %{rect | x: max(rect.x, 0), y: max(rect.y, 0)}
    {%{rect | width: max(right - rect.x, 1), height: max(bottom - rect.y, 1)}, covered}
  end

  defp regions({%Popup{} = popup, area}) do
    width = min(popup.fixed_width || div(area.width * popup.percent_width, 100), area.width)
    height = min(popup.fixed_height || div(area.height * popup.percent_height, 100), area.height)

    rect = %Rect{
      x: area.x + div(area.width - width, 2),
      y: area.y + div(area.height - height, 2),
      width: width,
      height: height
    }

    block_regions(popup.block, rect) ++
      if(popup.content, do: regions({popup.content, inner(popup.block, rect)}), else: [])
  end

  defp regions({%Block{} = block, rect}), do: block_regions(block, rect)
  defp regions({widget, rect}), do: block_regions(Map.get(widget, :block), rect)

  defp block_regions(nil, rect), do: [rect]

  defp block_regions(block, rect) do
    content = inner(block, rect)

    [
      %Rect{x: rect.x, y: rect.y, width: rect.width, height: content.y - rect.y},
      %Rect{
        x: rect.x,
        y: content.y + content.height,
        width: rect.width,
        height: rect.y + rect.height - content.y - content.height
      },
      %Rect{x: rect.x, y: content.y, width: content.x - rect.x, height: content.height},
      %Rect{
        x: content.x + content.width,
        y: content.y,
        width: rect.x + rect.width - content.x - content.width,
        height: content.height
      },
      content
    ]
    |> Enum.filter(&(&1.width > 0 and &1.height > 0))
  end

  defp inner(nil, rect), do: rect

  defp inner(block, rect) do
    {pl, pr, pt, pb} = block.padding
    border = fn side -> if :all in block.borders or side in block.borders, do: 1, else: 0 end
    left = min(pl + border.(:left), rect.width)
    top = min(pt + border.(:top), rect.height)

    %Rect{
      x: rect.x + left,
      y: rect.y + top,
      width: max(rect.width - left - pr - border.(:right), 0),
      height: max(rect.height - top - pb - border.(:bottom), 0)
    }
  end
end
