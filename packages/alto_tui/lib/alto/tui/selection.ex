defmodule Alto.TUI.Selection do
  @moduledoc """
  Content selection shared by terminal clients. The frame is captured once on
  mouse-down; subsequent motion only updates highlighted runs. Clients supply
  selectable content rectangles. Alt+drag explicitly opts into UI text.
  """

  alias Alto.TUI.{Layout, SelectionRegions}
  alias ExRatatui.{CellSession, Style}
  alias ExRatatui.Event.{FocusLost, Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, TextInput, Textarea, Image, Popup}

  defstruct [
    :snapshot,
    :anchor,
    :head,
    :press,
    :region,
    :menu,
    :scroll,
    dragged?: false,
    active?: false,
    highlight: []
  ]

  def new, do: %__MODULE__{}

  @doc "Route selection before ordinary clicks. :content returns selectable rectangles."
  def event(selection, event, dimensions, widgets, opts \\ [])
  def event(_, %Resize{}, _, _, _), do: {:pass, new()}
  def event(_, %Paste{}, _, _, _), do: {:pass, new()}

  def event(selection, %FocusLost{}, _, _, _),
    do: {:pass, %{stop_scroll(selection) | press: nil}}

  def event(selection, %Key{kind: "release"}, _, _, _), do: {:pass, selection}

  def event(selection, %Key{code: code, modifiers: modifiers}, dimensions, widgets, opts) do
    copy? =
      (String.downcase(code || "") == "c" and "ctrl" in modifiers) or
        (code == "c" and modifiers == ["alt"])

    cond do
      code == "esc" and selection.menu != nil ->
        {:handled, %{selection | menu: nil, press: nil}}

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
        %{press: :copy} = selection,
        %Mouse{kind: "up", button: "left", x: x, y: y},
        _,
        _,
        _
      ) do
    if Layout.contains?(selection.menu, x, y),
      do: {:copy, text(selection), new()},
      else: {:handled, %{selection | press: nil, menu: nil}}
  end

  def event(%{press: :copy} = selection, %Mouse{}, _, _, _), do: {:handled, selection}

  def event(selection, %Mouse{kind: "down", button: "left"} = mouse, dimensions, widgets, opts) do
    cond do
      Layout.contains?(selection.menu, mouse.x, mouse.y) ->
        {:handled, %{selection | press: :copy}}

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
      kind == "drag" -> {:handled, track_scroll(next, {x, y})}
      moved? -> {:handled, %{stop_scroll(next) | press: nil}}
      true -> {:click, selection.press, new()}
    end
  end

  def event(
        %{press: %Mouse{}, scroll: scroll} = selection,
        %Mouse{kind: kind, x: x, y: y},
        _,
        _,
        _
      )
      when not is_nil(scroll) and kind in ["scroll_up", "scroll_down"] do
    delta = if kind == "scroll_up", do: -3, else: 3
    selection = %{selection | head: clamp_region({x, y}, selection.region), active?: true}

    {:handled,
     selection |> stop_scroll() |> highlight() |> scroll_by(delta) |> track_scroll({x, y})}
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

      snapshot = capture(rendered, dimensions, [region], covered)
      selection = %{pressed | region: region, snapshot: snapshot}
      {:handled, %{selection | scroll: scroll_source(selection, dimensions, covered, opts)}}
    end
  end

  # Scroll only the paragraph that owns the gesture. Keep its source frozen,
  # and retain visited logical rows so copying includes text outside the viewport.
  defp scroll_source(selection, dimensions, covered, opts) do
    selection.snapshot.source_widgets
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {{%Paragraph{text: text, scroll: {offset, _}} = widget, rect}, index}
      when is_binary(text) or is_struct(text, ExRatatui.Text) ->
        inner = SelectionRegions.content_rect(widget, rect)

        if inner == selection.region do
          limit =
            Keyword.get(opts, :scroll_limit, fn _point ->
              cond do
                is_struct(text, ExRatatui.Text) ->
                  max(length(text.lines) - inner.height, 0)

                widget.wrap ->
                  Alto.TUI.Viewport.bottom(text, inner.width, inner.height)

                true ->
                  max(length(String.split(String.trim_trailing(text), "\n")) - inner.height, 0)
              end
            end)

          %{
            index: index,
            offset: offset,
            limit: limit.(selection.anchor),
            dimensions: dimensions,
            covered: covered,
            history: nil,
            pointer: selection.anchor,
            token: nil,
            timer: nil,
            origin: selection.anchor
          }
        end

      _ ->
        nil
    end)
  end

  defp track_scroll(%{scroll: nil} = selection, _point), do: selection

  defp track_scroll(selection, point) do
    selection = %{selection | scroll: %{selection.scroll | pointer: point}}
    if edge_delta(selection) == 0, do: stop_scroll(selection), else: arm_scroll(selection)
  end

  defp edge_delta(%{press: %Mouse{}, active?: true, scroll: %{pointer: {_x, y}}, region: rect}) do
    cond do
      y <= rect.y -> -1
      y >= rect.y + rect.height - 1 -> 1
      true -> 0
    end
  end

  defp edge_delta(_), do: 0

  defp arm_scroll(%{scroll: %{token: nil}} = selection) do
    token = make_ref()
    timer = Process.send_after(self(), {:tui_selection_scroll, token}, 30)
    %{selection | scroll: %{selection.scroll | token: token, timer: timer}}
  end

  defp arm_scroll(selection), do: selection

  defp stop_scroll(%{scroll: nil} = selection), do: selection

  defp stop_scroll(selection) do
    if selection.scroll.timer, do: Process.cancel_timer(selection.scroll.timer)
    %{selection | scroll: %{selection.scroll | token: nil, timer: nil}}
  end

  @doc "Advance an edge-held drag; stale timers cannot move a released selection."
  def autoscroll(%{scroll: %{token: token}} = selection, token) when not is_nil(token) do
    delta = edge_delta(selection)
    selection = stop_scroll(selection)
    next = if delta == 0, do: selection, else: scroll_by(selection, delta)

    if next.scroll.offset == selection.scroll.offset,
      do: {:idle, next},
      else: {:scrolled, arm_scroll(next)}
  end

  def autoscroll(selection, _token), do: {:idle, selection}

  @doc "Current scroll position and original hit point for the owning client's pane."
  def scroll_position(%{scroll: %{history: history, origin: origin, offset: offset}})
      when not is_nil(history),
      do: {origin, offset}

  def scroll_position(_), do: nil

  defp scroll_by(selection, delta) do
    scroll = selection.scroll
    limit = scroll.limit

    offset =
      if is_integer(limit), do: min(max(scroll.offset + delta, 0), limit), else: scroll.offset

    # Never skip rows when traversing a small viewport.
    offset =
      min(
        max(offset, scroll.offset - selection.region.height),
        scroll.offset + selection.region.height
      )

    if offset == scroll.offset do
      %{selection | scroll: scroll}
    else
      history =
        remember_rows(scroll.history || %{}, selection.snapshot, selection.region, scroll.offset)

      widgets =
        List.update_at(selection.snapshot.source_widgets, scroll.index, fn {widget, rect} ->
          {_, horizontal} = widget.scroll
          {%{widget | scroll: {offset, horizontal}}, rect}
        end)

      snapshot = capture(widgets, scroll.dimensions, [selection.region], scroll.covered)
      history = remember_rows(history, snapshot, selection.region, offset)
      {ax, ay} = selection.anchor

      %{
        selection
        | anchor: {ax, ay - (offset - scroll.offset)},
          snapshot: snapshot,
          scroll: %{scroll | offset: offset, history: history}
      }
      |> highlight()
    end
  end

  defp remember_rows(history, snapshot, rect, offset) do
    Enum.reduce(rect.y..(rect.y + rect.height - 1), history, fn y, rows ->
      key = y + offset - rect.y

      if Map.has_key?(rows, key) do
        rows
      else
        row = elem(snapshot.rows, y)
        # Do not retain a full frame binary for each off-screen line.
        Map.put(rows, key, %{row | raw: :binary.copy(row.raw)})
      end
    end)
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

  def widgets(%{snapshot: %{widgets: widgets}, press: %Mouse{}}, _live), do: widgets

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
      {y,
       segments(
         selected_row(selection, y),
         if(y == fy, do: fx, else: 0),
         if(y == ly, do: lx, else: selection.snapshot.width)
       )}
    end
  end

  defp selected_row(%{scroll: %{history: history, offset: offset}, region: region}, y)
       when not is_nil(history),
       do: Map.fetch!(history, y + offset - region.y)

  defp selected_row(selection, y), do: elem(selection.snapshot.rows, y)

  defp segments(row, low, high) do
    Enum.flat_map(indexed_runs(row), fn run ->
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
        {col, col + 1, col, col + 1}

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
      Enum.flat_map(max(fy, 0)..min(ly, tuple_size(selection.snapshot.rows) - 1), fn y ->
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

  defp clamp_region({x, y}, rect),
    do:
      {max(rect.x, min(x, rect.x + rect.width - 1)),
       max(rect.y, min(y, rect.y + rect.height - 1))}

  defp capture(widgets, {width, height}, content, covered) do
    # Keep immutable widget terms for paint, and export only the screen's text.
    # Exporting 48,000 cell maps just to start a drag causes a visible pause.
    widgets = Enum.map(widgets, fn {widget, rect} -> {freeze(widget), rect} end)
    terminal = capture_terminal(max(width, 1), max(height, 1))
    # TestBackend retains cells skipped by wide-glyph diffs. Blank the frame
    # before reuse so moving a double-width glyph cannot leave stale copy text.
    :ok = ExRatatui.draw(terminal, [])
    :ok = ExRatatui.draw(terminal, Alto.TUI.Viewport.widgets(widgets))
    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    lines = List.to_tuple(lines)

    rows =
      for y <- 0..(max(height, 1) - 1) do
        raw = if y < tuple_size(lines), do: elem(lines, y), else: ""
        ranges = if content == :all, do: [{0, width}], else: ranges(content, y, width)
        ranges = Enum.reduce(ranges(covered, y, width), ranges, &subtract/2)

        %{
          raw: raw,
          width: width,
          ranges: ranges,
          highlight:
            Enum.map(ranges, fn {x, right} -> highlight_widget({x, right - x, ""}, y) end)
        }
      end

    rows = List.to_tuple(rows)
    painted = widgets |> Enum.map(&crop_history(&1, rows)) |> Alto.TUI.Viewport.widgets()
    %{rows: rows, width: width, widgets: painted, source_widgets: widgets}
  end

  # A frozen Paragraph can still reflow thousands of off-screen lines in Rust
  # on every paint. Replace large plain paragraphs with their already-rendered
  # viewport, retaining the original block and style. Rich text keeps its spans.
  defp crop_history({%Paragraph{text: text, scroll: {offset, _}} = widget, rect}, rows)
       when is_binary(text) do
    if byte_size(text) > max(rect.width * rect.height * 2, 4096) or
         (offset > 0 and byte_size(text) > 4096) do
      inner = SelectionRegions.content_rect(widget, rect)
      bottom = min(inner.y + inner.height, tuple_size(rows))

      if bottom > inner.y and inner.width > 0 do
        text =
          Enum.map_join(inner.y..(bottom - 1), "\n", fn y ->
            row = elem(rows, y)
            right = min(inner.x + inner.width, row.width)
            ranges = if right > inner.x, do: [{inner.x, right}], else: []

            segments(%{row | ranges: ranges}, inner.x, right - 1)
            |> Enum.map_join(fn {_, _, text} -> text end)
          end)

        {%{widget | text: text, scroll: {0, 0}, wrap: false, alignment: :left}, rect}
      else
        {widget, rect}
      end
    else
      {widget, rect}
    end
  end

  defp crop_history(other, _rows), do: other

  # Reuse native buffers between gestures instead of allocating an entire second
  # terminal on each click. Every capture still redraws the current widgets.
  defp capture_terminal(width, height) do
    key = {__MODULE__, :capture_terminal}

    case Process.get(key) do
      {^width, ^height, terminal} ->
        terminal

      _ ->
        terminal = ExRatatui.init_test_terminal(width, height)
        Process.put(key, {width, height, terminal})
        terminal
    end
  end

  @doc false
  def buffer_row_text(raw, width) do
    [%{text: text}] = indexed_runs(%{raw: raw, width: width, ranges: [{0, width}]})
    text
  end

  # Only the two boundary rows need a glyph index during motion. Interior rows
  # use cached rectangles; their text is indexed only if the user copies it.
  defp indexed_runs(row) do
    tokens = Enum.reject(tokens(row.raw), &(&1 == {:ascii, ""}))
    symbols = for {:glyph, glyph} <- tokens, do: glyph
    widths = symbol_widths(symbols)
    {parts, points, col, _offset} = index_row(tokens, widths, [], [], 0, 0)

    text =
      IO.iodata_to_binary([Enum.reverse(parts), String.duplicate(" ", max(row.width - col, 0))])

    points = points |> Enum.reverse() |> List.to_tuple()

    Enum.map(row.ranges, fn {left, right} ->
      %{x: left, right: right, text: text, points: points}
    end)
  end

  # Native buffers contain one filler cell after a double-width glyph. Remove
  # that filler while indexing columns; combining marks remain in their glyph.
  defp index_row([], _widths, parts, points, col, offset), do: {parts, points, col, offset}

  defp index_row([{:ascii, text} | rest], widths, parts, points, col, offset) do
    size = byte_size(text)
    index_row(rest, widths, [text | parts], points, col + size, offset + size)
  end

  defp index_row([{:glyph, glyph} | rest], widths, parts, points, col, offset) do
    width = Map.fetch!(widths, glyph)
    size = byte_size(glyph)
    points = [{col, col + width, offset, offset + size} | points]

    rest =
      case {width, rest} do
        {w, [{:ascii, text} | tail]} when w > 1 ->
          skip = min(w - 1, byte_size(text))
          [{:ascii, binary_part(text, skip, byte_size(text) - skip)} | tail]

        _ ->
          rest
      end

    index_row(rest, widths, [glyph | parts], points, col + width, offset + size)
  end

  # Keep entire ASCII runs as binaries. Only Unicode needs grapheme segmentation;
  # include the preceding ASCII character so e + combining accent stays intact.
  defp tokens(""), do: []

  defp tokens(text) do
    case Regex.run(~r/[^\x00-\x7F]/, text, return: :index) do
      nil ->
        [{:ascii, text}]

      [{offset, _}] ->
        prefix = max(offset - 1, 0)
        <<ascii::binary-size(prefix), rest::binary>> = text
        {glyph, rest} = String.next_grapheme(rest)
        token = if byte_size(glyph) == 1, do: {:ascii, glyph}, else: {:glyph, glyph}
        [{:ascii, ascii}, token | tokens(rest)]
    end
  end

  defp ranges(rects, y, width) do
    rects
    |> Enum.filter(&(y >= &1.y and y < &1.y + &1.height))
    |> Enum.map(&{max(&1.x, 0), min(&1.x + &1.width, width)})
    |> Enum.filter(fn {left, right} -> right > left end)
    |> Enum.sort()
    |> Enum.reduce([], fn {left, right}, acc ->
      case acc do
        [{a, b} | rest] when left <= b -> [{a, max(b, right)} | rest]
        _ -> [{left, right} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp subtract({left, right}, ranges) do
    Enum.flat_map(ranges, fn {a, b} ->
      if b <= left or a >= right do
        [{a, b}]
      else
        [{a, min(b, left)}, {max(a, right), b}] |> Enum.filter(fn {x, z} -> z > x end)
      end
    end)
  end

  defp freeze(%TextInput{state: ref} = widget) when is_reference(ref),
    do: %{widget | state: ExRatatui.Native.text_input_snapshot(ref)}

  defp freeze(%Textarea{state: ref} = widget) when is_reference(ref),
    do: %{widget | state: ExRatatui.Native.textarea_snapshot(ref)}

  defp freeze(%Image{state: ref} = widget) when is_reference(ref),
    do: %{widget | state: ExRatatui.Native.image_snapshot(ref)}

  defp freeze(%Popup{content: content} = widget), do: %{widget | content: freeze(content)}
  defp freeze(widget), do: widget

  # Batch Unicode width probes into one native draw/read instead of one native
  # roundtrip per distinct character. ASCII needs no probe.
  @doc false
  def glyph_widths(symbols), do: symbol_widths(symbols)

  defp symbol_widths(symbols) do
    key = {__MODULE__, :glyph_widths}
    cached = Process.get(key, %{})
    missing = symbols |> Enum.uniq() |> Enum.reject(&Map.has_key?(cached, &1))

    if missing == [] do
      cached
    else
      widths =
        Map.merge(if(map_size(cached) > 1024, do: %{}, else: cached), probe_widths(missing))

      Process.put(key, widths)
      Map.merge(cached, widths)
    end
  end

  defp probe_widths(symbols) do
    symbols = symbols |> Enum.uniq() |> Enum.reject(&(byte_size(&1) == 1))

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
