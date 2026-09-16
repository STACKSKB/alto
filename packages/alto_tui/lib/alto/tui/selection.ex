defmodule Alto.TUI.Selection do
  @moduledoc """
  Content selection shared by terminal clients. The frame is captured once on
  mouse-down; subsequent motion only updates highlighted runs. Clients supply
  selectable content rectangles. Alt+drag explicitly opts into UI text.
  """

  alias Alto.TUI.{Layout, SelectionRegions}
  alias ExRatatui.{CellSession, Style, Text}
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}

  defstruct [
    :snapshot,
    :anchor,
    :head,
    :press,
    :region,
    :menu,
    copy_press: false,
    dragged?: false,
    active?: false,
    highlight: []
  ]

  def new, do: %__MODULE__{}

  @doc "Route selection before ordinary clicks. :content returns selectable rectangles."
  def event(selection, event, dimensions, widgets, opts \\ [])
  def event(_, %Resize{}, _, _, _), do: {:pass, new()}
  def event(_, %Paste{}, _, _, _), do: {:pass, new()}
  def event(selection, %Key{kind: "release"}, _, _, _), do: {:pass, selection}

  def event(selection, %Key{code: code, modifiers: modifiers}, dimensions, widgets, opts) do
    copy? =
      (String.downcase(code || "") == "c" and "ctrl" in modifiers) or
        (code == "c" and modifiers == ["alt"])

    cond do
      code == "esc" and selection.menu != nil ->
        {:handled, %{selection | menu: nil, copy_press: false}}

      code == "esc" and (selection.active? or selection.press != nil) ->
        {:handled, new()}

      (copy? or (selection.menu != nil and code in ["enter", "c"])) and selection.active? ->
        {:copy, text(selection), new()}

      copy? and ("shift" in modifiers or "alt" in modifiers) ->
        {:handled, selection}

      String.downcase(code || "") == "a" and "ctrl" in modifiers and "shift" in modifiers ->
        {width, height} = dimensions
        content = content(opts, modifiers)

        if content == [] do
          {:handled, new()}
        else
          rendered = widgets.()
          snapshot = capture(rendered, dimensions, content, [])

          {:handled,
           highlight(%__MODULE__{
             snapshot: snapshot,
             anchor: {0, 0},
             head: {width - 1, height - 1},
             active?: true
           })}
        end

      true ->
        {:pass, new()}
    end
  end

  def event(
        %{active?: true} = selection,
        %Mouse{kind: "down", button: "right", x: x, y: y},
        {width, height},
        _,
        _
      ) do
    # A normal context-menu row, without a title, frame or selection toolbar.
    menu = %Rect{
      x: max(min(x, width - 22), 0),
      y: max(min(y, height - 1), 0),
      width: min(width, 22),
      height: 1
    }

    {:handled, %{selection | menu: menu, press: nil}}
  end

  def event(%{active?: true} = selection, %Mouse{button: "right"}, _, _, _),
    do: {:handled, selection}

  def event(
        %{copy_press: true} = selection,
        %Mouse{kind: "up", button: "left", x: x, y: y},
        _,
        _,
        _
      ) do
    if Layout.contains?(selection.menu, x, y),
      do: {:copy, text(selection), new()},
      else: {:handled, %{selection | copy_press: false, menu: nil}}
  end

  def event(%{copy_press: true} = selection, %Mouse{}, _, _, _), do: {:handled, selection}

  def event(selection, %Mouse{kind: "down", button: "left"} = mouse, dimensions, widgets, opts) do
    cond do
      Layout.contains?(selection.menu, mouse.x, mouse.y) ->
        {:handled, %{selection | copy_press: true}}

      selection.menu != nil ->
        {:handled, %{selection | menu: nil}}

      true ->
        start_selection(mouse, dimensions, widgets, opts)
    end
  end

  # Chrome clicks do not capture or render a second screen. Still defer the click
  # until release so dragging over an approval button cannot activate it.
  def event(
        %{press: %Mouse{}, snapshot: nil} = selection,
        %Mouse{kind: kind, x: x, y: y},
        _,
        _,
        _
      )
      when kind in ["drag", "up"] do
    moved? = selection.dragged? or kind == "drag" or {x, y} != selection.anchor

    cond do
      kind == "drag" -> {:handled, %{selection | dragged?: moved?}}
      moved? -> {:handled, new()}
      true -> {:click, selection.press, new()}
    end
  end

  def event(%{press: %Mouse{}} = selection, %Mouse{kind: kind, x: x, y: y}, _, _, _)
      when kind in ["drag", "up"] do
    point = clamp_region({x, y}, selection.region)
    moved? = selection.active? or kind == "drag" or {x, y} != selection.anchor

    next =
      if point == selection.head and moved? == selection.active?,
        do: selection,
        else: highlight(%{selection | head: point, active?: moved?})

    cond do
      kind == "drag" -> {:handled, next}
      moved? -> {:handled, %{next | press: nil}}
      true -> {:click, selection.press, new()}
    end
  end

  def event(_, %Mouse{kind: kind}, _, _, _) when kind in ["scroll_up", "scroll_down"],
    do: {:pass, new()}

  def event(selection, _, _, _, _), do: {:pass, selection}

  defp content(opts, modifiers) do
    if "alt" in modifiers, do: :all, else: Keyword.get(opts, :content, fn -> :all end).()
  end

  defp start_selection(mouse, {width, height} = dimensions, widgets, opts) do
    point = {max(0, min(mouse.x, width - 1)), max(0, min(mouse.y, height - 1))}
    content = content(opts, mouse.modifiers)

    allowed =
      if content == :all,
        do: :all,
        else: Enum.find(content, &Layout.contains?(&1, mouse.x, mouse.y))

    pressed = %__MODULE__{anchor: point, head: point, press: mouse}

    if allowed == nil do
      {:handled, pressed}
    else
      rendered = widgets.()
      {region, covered} = SelectionRegions.at(rendered, point, dimensions)
      region = if allowed == :all, do: region, else: intersection(region, allowed)

      {:handled,
       %{pressed | region: region, snapshot: capture(rendered, dimensions, [region], covered)}}
    end
  end

  defp intersection(a, b) do
    x = max(a.x, b.x)
    y = max(a.y, b.y)

    %Rect{
      x: x,
      y: y,
      width: min(a.x + a.width, b.x + b.width) - x,
      height: min(a.y + a.height, b.y + b.height) - y
    }
  end

  @doc "Use a lazy live view so a drag never rebuilds conversation history."
  def widgets(%{active?: true} = selection, _live),
    do: selection.snapshot.widgets ++ selection.highlight ++ menu_widgets(selection.menu)

  def widgets(_, live) when is_function(live, 0), do: live.()
  def widgets(_, live), do: live

  defp menu_widgets(nil), do: []

  defp menu_widgets(rect) do
    bg = {:rgb, 43, 48, 57}
    label = Span.new(" Copy         ", style: %Style{fg: :white, bg: bg})

    shortcut =
      Span.new("Ctrl+C  ", style: %Style{fg: {:rgb, 155, 162, 174}, bg: bg, modifiers: [:dim]})

    [{%Paragraph{text: Line.new([label, shortcut]), style: %Style{bg: bg}}, rect}]
  end

  @doc "Return visible selected content, with row padding removed."
  def text(%{active?: false}), do: ""

  def text(selection) do
    selected_rows(selection)
    |> Enum.map_join("\n", fn {_y, runs} ->
      Enum.map_join(runs, fn {_x, _width, text} -> text end) |> String.trim_trailing(" ")
    end)
  end

  defp bounds(%{anchor: {ax, ay}, head: {hx, hy}}), do: Enum.min_max([{ay, ax}, {hy, hx}])

  defp selected_rows(selection) do
    {{fy, fx}, {ly, lx}} = bounds(selection)

    for y <- fy..ly do
      row = elem(selection.snapshot.rows, y)

      {y,
       segments(
         row,
         if(y == fy, do: fx, else: 0),
         if(y == ly, do: lx, else: selection.snapshot.width)
       )}
    end
  end

  defp segments(row, low, high) do
    Enum.flat_map(row.runs, fn run ->
      if run.right <= low or run.x > high do
        []
      else
        {x, _, first, _} = point_at(run, max(low, run.x))
        {_, right, _, last} = point_at(run, min(high, run.right - 1))
        [{x, right - x, binary_part(run.text, first, last - first)}]
      end
    end)
  end

  # ASCII columns map directly to byte offsets. Store only Unicode exceptions,
  # avoiding a tuple for every blank/ASCII cell in a large terminal snapshot.
  defp point_at(run, col) do
    case preceding(run.points, col, 0, tuple_size(run.points) - 1, nil) do
      nil ->
        {col, col + 1, col - run.x, col - run.x + 1}

      {_x, right, _first, last} = point ->
        if col < right,
          do: point,
          else: {col, col + 1, last + col - right, last + col - right + 1}
    end
  end

  defp preceding(_points, _col, low, high, found) when low > high, do: found

  defp preceding(points, col, low, high, found) do
    middle = div(low + high, 2)
    {x, _, _, _} = point = elem(points, middle)

    if x <= col,
      do: preceding(points, col, middle + 1, high, point),
      else: preceding(points, col, low, middle - 1, found)
  end

  defp highlight(%{active?: false} = selection), do: selection

  defp highlight(selection) do
    {{fy, fx}, {ly, lx}} = bounds(selection)

    widgets =
      Enum.flat_map(fy..ly, fn y ->
        row = elem(selection.snapshot.rows, y)

        if y > fy and y < ly do
          row.highlight
        else
          segments(
            row,
            if(y == fy, do: fx, else: 0),
            if(y == ly, do: lx, else: selection.snapshot.width)
          )
          |> Enum.map(&highlight_widget(&1, y))
        end
      end)

    %{selection | highlight: widgets}
  end

  # A borderless block changes cell styles without shaping/drawing the text again.
  defp highlight_widget({x, width, _text}, y),
    do:
      {%Block{style: %Style{fg: :black, bg: :light_blue}},
       %Rect{x: x, y: y, width: width, height: 1}}

  defp cached_row(cells, y) do
    {groups, _} =
      Enum.reduce(cells, {[], -1}, fn {cell, width} = entry, {groups, right} ->
        if cell.col == right do
          [group | rest] = groups
          {[[entry | group] | rest], cell.col + width}
        else
          {[[entry] | groups], cell.col + width}
        end
      end)

    runs =
      groups
      |> Enum.reverse()
      |> Enum.map(fn group ->
        group = Enum.reverse(group)

        {points, _} =
          Enum.reduce(group, {[], 0}, fn {cell, width}, {points, offset} ->
            size = byte_size(cell.symbol)
            last = offset + size

            points =
              if size == width,
                do: points,
                else: [{cell.col, cell.col + width, offset, last} | points]

            {points, last}
          end)

        {first, _} = hd(group)
        {last, width} = List.last(group)

        %{
          x: first.col,
          right: last.col + width,
          text: Enum.map_join(group, fn {cell, _} -> cell.symbol end),
          points: points |> Enum.reverse() |> List.to_tuple()
        }
      end)

    %{
      runs: runs,
      highlight: Enum.map(runs, &highlight_widget({&1.x, &1.right - &1.x, &1.text}, y))
    }
  end

  defp clamp_region({x, y}, rect),
    do:
      {max(rect.x, min(x, rect.x + rect.width - 1)),
       max(rect.y, min(y, rect.y + rect.height - 1))}

  defp capture(widgets, {width, height}, content, covered) do
    session = CellSession.new(max(width, 1), max(height, 1))

    try do
      :ok = CellSession.draw(session, widgets)
      snapshot = CellSession.take_cells(session)
      widths = symbol_widths(snapshot.cells)

      rows =
        snapshot.cells
        |> Enum.chunk_every(snapshot.width)
        |> Enum.map(fn cells ->
          {row, _} =
            Enum.reduce(cells, {[], 0}, fn cell, {row, next_col} ->
              if cell.col < next_col do
                {row, next_col}
              else
                width = Map.get(widths, cell.symbol, 1)
                {[{cell, width} | row], cell.col + width}
              end
            end)

          Enum.reverse(row)
        end)

      # Coalesce equal styles once, instead of serializing one span per cell on
      # every mouse event. Keep immutable widgets ready for the native renderer.
      lines =
        Enum.map(rows, fn cells ->
          cells
          |> Enum.chunk_by(fn {cell, _} -> {cell.fg, cell.bg, cell.modifiers} end)
          |> Enum.map(fn [{cell, _} | _] = run ->
            Span.new(Enum.map_join(run, fn {c, _} -> c.symbol end),
              style: %Style{fg: cell.fg, bg: cell.bg, modifiers: cell.modifiers}
            )
          end)
          |> Line.new()
        end)

      selectable =
        Enum.map(rows, fn cells ->
          Enum.filter(cells, fn {cell, _} ->
            (content == :all or Enum.any?(content, &Layout.contains?(&1, cell.col, cell.row))) and
              not Enum.any?(covered, &Layout.contains?(&1, cell.col, cell.row))
          end)
        end)

      %{
        rows:
          selectable
          |> Enum.with_index()
          |> Enum.map(fn {cells, y} -> cached_row(cells, y) end)
          |> List.to_tuple(),
        width: snapshot.width,
        widgets: [
          {%Paragraph{text: Text.new(lines)},
           %Rect{width: snapshot.width, height: snapshot.height}}
        ]
      }
    after
      CellSession.close(session)
    end
  end

  # Batch Unicode width probes into one native draw/read instead of one native
  # roundtrip per distinct character. ASCII needs no probe.
  defp symbol_widths(cells) do
    symbols = cells |> Enum.map(& &1.symbol) |> Enum.uniq() |> Enum.reject(&(byte_size(&1) == 1))

    if symbols == [] do
      %{}
    else
      probe = CellSession.new(8, length(symbols))

      try do
        widgets =
          symbols
          |> Enum.with_index()
          |> Enum.map(fn {symbol, y} ->
            {%Paragraph{text: symbol <> "x"}, %Rect{y: y, width: 8, height: 1}}
          end)

        :ok = CellSession.draw(probe, widgets)

        widths =
          CellSession.take_cells(probe).cells
          |> Enum.filter(&(&1.symbol == "x"))
          |> Map.new(&{&1.row, max(&1.col, 1)})

        symbols
        |> Enum.with_index()
        |> Map.new(fn {symbol, y} -> {symbol, Map.fetch!(widths, y)} end)
      after
        CellSession.close(probe)
      end
    end
  end
end
