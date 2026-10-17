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
        for {item, layout, first, count} <- plan.parts,
            start = max(offset, first),
            stop = min(last, first + count),
            stop > start,
            {row, n} <-
              Enum.with_index(render.(item, layout, start - first, stop - start), start),
            into: %{},
            do: {n, row}

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
