defmodule Alto.TUI.Window do
  @moduledoc "Visible styled rows with their absolute position and complete history size."
  @enforce_keys [:lines, :offset, :rows]
  defstruct [:lines, :offset, :rows]

  alias ExRatatui.Text
  alias ExRatatui.Text.Line

  @doc "Render intersecting parts while retaining their absolute rows and blank separators."
  def slice(plan, offset, height, render) do
    last = min(offset + height, plan.rows)

    if last <= offset do
      []
    else
      rows =
        Enum.reduce(plan.parts, %{}, fn {item, layout, first, count}, acc ->
          start = max(offset, first)
          stop = min(last, first + count)

          if stop > start do
            render.(item, layout, start - first, stop - start)
            |> Enum.with_index(start)
            |> Enum.reduce(acc, fn {row, n}, acc -> Map.put(acc, n, row) end)
          else
            acc
          end
        end)

      Enum.map(offset..(last - 1), &Map.get(rows, &1, Line.new([])))
    end
  end

  @doc "Collect only enough final parts to fill a viewport, including separators."
  def tail(items, height, render) do
    {groups, _} =
      items
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn item, {groups, count} ->
        {rows, total_rows} = render.(item)
        count = count + total_rows + if(groups == [], do: 0, else: 1)
        result = {[rows | groups], count}
        if count >= height, do: {:halt, result}, else: {:cont, result}
      end)

    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten() |> Enum.take(-height))
  end
end
