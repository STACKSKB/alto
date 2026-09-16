defmodule Alto.TUI.Selection do
  @moduledoc """
  Selection of the final rendered screen, shared by terminal clients.

  A snapshot includes borders, overlays and masked fields exactly as displayed.
  It is frozen during selection so streaming updates cannot change copied text.
  Clients defer ordinary click actions until release, allowing drags over buttons
  and task rows without activating them.
  """

  alias ExRatatui.{CellSession, Style, Text}
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  defstruct [:snapshot, :anchor, :head, :press, active?: false]

  def new, do: %__MODULE__{}

  @doc "Route selection gestures before a client's normal event handling."
  def event(selection, event, dimensions, widgets)

  def event(_selection, %Resize{}, _dimensions, _widgets), do: {:pass, new()}
  def event(_selection, %Paste{}, _dimensions, _widgets), do: {:pass, new()}
  def event(selection, %Key{kind: "release"}, _, _), do: {:pass, selection}

  def event(selection, %Key{code: code, modifiers: modifiers}, dimensions, widgets) do
    copy? =
      (String.downcase(code || "") == "c" and "ctrl" in modifiers) or
        (code == "c" and modifiers == ["alt"])

    cond do
      code == "esc" and (selection.active? or selection.press != nil) ->
        {:handled, new()}

      copy? and selection.active? ->
        {:copy, text(selection), new()}

      copy? and ("shift" in modifiers or "alt" in modifiers) ->
        {:handled, selection}

      String.downcase(code || "") == "a" and "ctrl" in modifiers and "shift" in modifiers ->
        snapshot = capture(widgets.(), dimensions)
        {width, height} = dimensions

        {:handled,
         %__MODULE__{
           snapshot: snapshot,
           anchor: {0, 0},
           head: {width - 1, height - 1},
           active?: true
         }}

      true ->
        {:pass, new()}
    end
  end

  def event(_selection, %Mouse{kind: "down", button: "left"} = mouse, dimensions, widgets) do
    point = clamp({mouse.x, mouse.y}, dimensions)

    {:handled,
     %__MODULE__{
       snapshot: capture(widgets.(), dimensions),
       anchor: point,
       head: point,
       press: mouse
     }}
  end

  def event(%{press: %Mouse{}} = selection, %Mouse{kind: kind, x: x, y: y}, dimensions, _)
      when kind in ["drag", "up"] do
    point = clamp({x, y}, dimensions)
    moved? = selection.active? or point != selection.anchor
    next = %{selection | head: point, active?: moved?}

    cond do
      kind == "drag" -> {:handled, next}
      moved? -> {:handled, %{next | press: nil}}
      true -> {:click, selection.press, new()}
    end
  end

  def event(_selection, %Mouse{kind: kind}, _, _) when kind in ["scroll_up", "scroll_down"],
    do: {:pass, new()}

  def event(selection, _event, _dimensions, _widgets), do: {:pass, selection}

  @doc "Render the frozen screen with a visible selection, or use the live widgets."
  def widgets(%{active?: true, snapshot: snapshot} = selection, _live) do
    lines =
      Enum.map(snapshot.rows, fn cells ->
        Line.new(
          Enum.map(cells, fn {cell, width} ->
            style =
              if selected?(selection, cell, width),
                do: %Style{fg: :black, bg: :light_blue},
                else: %Style{fg: cell.fg, bg: cell.bg, modifiers: cell.modifiers}

            Span.new(cell.symbol, style: style)
          end)
        )
      end)

    [{%Paragraph{text: Text.new(lines)}, %Rect{width: snapshot.width, height: snapshot.height}}]
  end

  def widgets(_selection, live), do: live

  @doc "Return only visible selected text, with terminal row padding removed."
  def text(%{active?: false}), do: ""

  def text(selection) do
    {first, last} = bounds(selection)

    selection.snapshot.rows
    |> Enum.slice(elem(first, 0)..elem(last, 0))
    |> Enum.map_join("\n", fn cells ->
      cells
      |> Enum.filter(fn {cell, width} -> selected?(selection, cell, width) end)
      |> Enum.map_join(fn {cell, _} -> cell.symbol end)
      |> String.trim_trailing(" ")
    end)
  end

  defp bounds(%{anchor: {ax, ay}, head: {hx, hy}}), do: Enum.min_max([{ay, ax}, {hy, hx}])

  defp selected?(selection, cell, width) do
    {first, last} = bounds(selection)
    {cell.row, cell.col + width - 1} >= first and {cell.row, cell.col} <= last
  end

  defp clamp({x, y}, {width, height}),
    do: {max(0, min(x, width - 1)), max(0, min(y, height - 1))}

  defp capture(widgets, {width, height}) do
    session = CellSession.new(max(width, 1), max(height, 1))

    try do
      :ok = CellSession.draw(session, widgets)
      snapshot = CellSession.take_cells(session)
      widths = symbol_widths(snapshot.cells)

      rows =
        snapshot.cells
        |> Enum.chunk_every(snapshot.width)
        |> Enum.map(fn cells ->
          {cells, _} =
            Enum.reduce(cells, {[], 0}, fn cell, {row, next_col} ->
              if cell.col < next_col do
                {row, next_col}
              else
                width = Map.fetch!(widths, cell.symbol)
                {[{cell, width} | row], cell.col + width}
              end
            end)

          Enum.reverse(cells)
        end)

      %{width: snapshot.width, height: snapshot.height, rows: rows}
    after
      CellSession.close(session)
    end
  end

  # Ask the same native renderer for display widths. This handles CJK, emoji,
  # combining marks and wide-cell continuations without a second Unicode table.
  defp symbol_widths(cells) do
    probe = CellSession.new(8, 1)

    try do
      cells
      |> Enum.map(& &1.symbol)
      |> Enum.uniq()
      |> Map.new(fn symbol ->
        width =
          if byte_size(symbol) == 1 do
            1
          else
            :ok =
              CellSession.draw(probe, [
                {%Paragraph{text: symbol <> "x"}, %Rect{width: 8, height: 1}}
              ])

            CellSession.take_cells(probe).cells
            |> Enum.find(&(&1.symbol == "x"))
            |> Map.fetch!(:col)
          end

        {symbol, max(width, 1)}
      end)
    after
      CellSession.close(probe)
    end
  end
end
