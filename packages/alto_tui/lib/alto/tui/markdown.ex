defmodule Alto.TUI.Markdown do
  @moduledoc "Streaming-safe report layout with cached blocks and responsive tables."
  alias ExRatatui.{CellSession, Style, Text}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Markdown, as: NativeMarkdown

  @accent {:rgb, 105, 180, 255}
  @muted {:rgb, 150, 160, 175}

  def render(source, width) do
    width = max(width, 1)
    key = {__MODULE__, :blocks}
    widths = Process.get(key, [])

    cache =
      case List.keyfind(widths, width, 0) do
        {_, cache} -> cache
        nil -> %{}
      end

    {groups, used} =
      source
      |> String.split("\n")
      |> blocks([])
      |> Enum.map_reduce(%{}, fn block, used ->
        id = {width, block}
        rows = Map.get_lazy(cache, id, fn -> render_block(block, width) end)
        {rows, Map.put(used, id, rows)}
      end)

    # Keep only the current version of each block at a few pane widths. A
    # streaming table must not retain hundreds of previous full-table layouts.
    Process.put(key, Enum.take([{width, used} | List.keydelete(widths, width, 0)], 3))
    Text.new(Enum.intersperse(groups, [Line.new([])]) |> List.flatten())
  end

  def plain(source, width) do
    render(source, width).lines
    |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  defp blocks([], acc), do: Enum.reverse(acc)
  defp blocks(["" | rest], acc), do: blocks(rest, acc)

  defp blocks([line | rest], acc) do
    cond do
      fence = fence(line) ->
        {code, rest} = take_code(rest, fence, [])
        blocks(rest, [{:code, elem(fence, 1), Enum.join(code, "\n")} | acc])

      indented?(line) ->
        {code, rest} = Enum.split_while([line | rest], &(indented?(&1) or String.trim(&1) == ""))

        code =
          code
          |> Enum.map(&Regex.replace(~r/^(?: {4}|\t)/, &1, ""))
          |> Enum.join("\n")
          |> String.trim_trailing("\n")

        blocks(rest, [{:code, "", code} | acc])

      setext?(rest) ->
        blocks(tl(rest), [{:heading, String.trim(line)} | acc])

      heading = Regex.run(~r/^ {0,3}(\#{1,6})[ \t]+(.+?)\s*$/, line) ->
        [_, _, text] = heading
        text = Regex.replace(~r/[ \t]+\#+[ \t]*$/, text, "")
        blocks(rest, [{:heading, text} | acc])

      rule?(line) ->
        blocks(rest, [:rule | acc])

      table?(line, rest) ->
        [_separator | rest] = rest

        {rows, rest} =
          Enum.split_while(rest, &(String.trim(&1) != "" and String.contains?(&1, "|")))

        blocks(rest, [{:table, cells(line), Enum.map(rows, &cells/1)} | acc])

      true ->
        {paragraph, rest} = take_paragraph(rest, [line])
        blocks(rest, [{:prose, Enum.join(paragraph, "\n")} | acc])
    end
  end

  defp indented?(line), do: String.starts_with?(line, ["    ", "\t"])
  defp setext?([line | _]), do: Regex.match?(~r/^ {0,3}(?:=+|-+)[ \t]*$/, line)
  defp setext?(_), do: false

  defp take_paragraph([], acc), do: {Enum.reverse(acc), []}

  defp take_paragraph([line | rest] = remaining, acc) do
    if String.trim(line) == "" or fence(line) != nil or rule?(line) or
         Regex.match?(~r/^ {0,3}\#{1,6}\s/, line) or table?(line, rest),
       do: {Enum.reverse(acc), remaining},
       else: take_paragraph(rest, [line | acc])
  end

  defp fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      [_, marker, language] -> {marker, String.trim(language)}
      _ -> nil
    end
  end

  defp take_code([], _, acc), do: {Enum.reverse(acc), []}

  defp take_code([line | rest], {marker, _} = opening, acc) do
    closing = String.trim(line)

    if String.length(closing) >= String.length(marker) and
         String.trim(closing, String.first(marker)) == "",
       do: {Enum.reverse(acc), rest},
       else: take_code(rest, opening, [line | acc])
  end

  defp rule?(line),
    do: Regex.match?(~r/^ {0,3}(?:\*\s*){3,}$|^ {0,3}(?:-\s*){3,}$|^ {0,3}(?:_\s*){3,}$/, line)

  defp table?(header, [separator | _]) do
    columns = cells(separator)

    String.contains?(header, "|") and length(columns) == length(cells(header)) and
      length(columns) > 1 and Enum.all?(columns, &Regex.match?(~r/^:?-{3,}:?$/, &1))
  end

  defp table?(_, _), do: false

  # Pipes inside inline code and escaped pipes are data, not column separators.
  defp cells(line) do
    tokens = Regex.scan(~r/\\.|`+|[^\\`|]+|\||./us, String.trim(line)) |> List.flatten()

    {parts, current, _} =
      Enum.reduce(tokens, {[], [], nil}, fn token, {parts, current, ticks} ->
        cond do
          token == "|" and ticks == nil ->
            {[Enum.reverse(current) |> Enum.join() | parts], [], ticks}

          String.starts_with?(token, "`") ->
            next = if ticks == token, do: nil, else: ticks || token
            {parts, [token | current], next}

          token == "\\|" ->
            {parts, ["|" | current], ticks}

          true ->
            {parts, [token | current], ticks}
        end
      end)

    result = Enum.reverse([Enum.reverse(current) |> Enum.join() | parts])
    result = if String.starts_with?(String.trim(line), "|"), do: tl(result), else: result

    result =
      if String.ends_with?(String.trim(line), "|") and List.last(result) == "",
        do: Enum.drop(result, -1),
        else: result

    Enum.map(result, &String.trim/1)
  end

  defp render_block(:rule, width),
    do: [Line.new([Span.new(String.duplicate("─", width), style: %Style{fg: @muted})])]

  defp render_block({:prose, text}, width), do: native(String.replace(text, "\n", "  \n"), width)

  defp render_block({:heading, text}, width) do
    native(text, width)
    |> Enum.map(fn line ->
      %{
        line
        | spans:
            Enum.map(line.spans, fn span ->
              %{
                span
                | style: %{
                    span.style
                    | fg: @accent,
                      modifiers: Enum.uniq([:bold | span.style.modifiers])
                  }
              }
            end)
      }
    end)
  end

  defp render_block({:code, language, code}, width) do
    label = if language == "", do: "code", else: language
    heading = Line.new([Span.new("  " <> label, style: %Style{fg: @muted})])

    rows =
      ExRatatui.CodeBlock.highlight(code, language, :base16_ocean_dark)
      |> Enum.flat_map(&wrap_code(&1, width))

    [heading | rows]
  end

  defp render_block({:table, headers, records}, width) do
    count = length(headers)
    # Keep partially streamed rows visible; never silently discard extra cells.
    count = Enum.reduce(records, count, &max(length(&1), &2))
    headers = headers ++ Enum.map((length(headers) + 1)..count//1, &"Column #{&1}")

    widths =
      for index <- 0..(count - 1),
          do:
            Enum.reduce([headers | records], 1, fn row, n ->
              max(n, byte_size(Enum.at(row, index, "")))
            end)

    if Enum.sum(widths) + (count - 1) * 3 <= width do
      table_grid(headers, records, widths)
    else
      if(records == [], do: [[]], else: records)
      |> Enum.map(fn row ->
        headers
        |> Enum.with_index()
        |> Enum.flat_map(fn {header, index} ->
          value = Enum.at(row, index, "")
          native("**#{header}:** #{value}", width)
        end)
      end)
      |> Enum.intersperse([Line.new([])])
      |> List.flatten()
    end
  end

  defp table_grid(headers, records, widths) do
    header = grid_row(headers, widths, true)

    rule =
      Line.new(
        Enum.intersperse(
          Enum.map(widths, &Span.new(String.duplicate("─", &1), style: %Style{fg: @muted})),
          Span.new("─┼─", style: %Style{fg: @muted})
        )
      )

    [header, rule | Enum.map(records, &grid_row(&1, widths, false))]
  end

  defp grid_row(values, widths, header?) do
    spans =
      widths
      |> Enum.with_index()
      |> Enum.map(fn {width, index} ->
        value = Enum.at(values, index, "")
        lines = native(value, max(width, 1))
        spans = Enum.flat_map(lines, & &1.spans)

        spans =
          if header?,
            do:
              Enum.map(
                spans,
                &%{&1 | style: %{&1.style | modifiers: Enum.uniq([:bold | &1.style.modifiers])}}
              ),
            else: spans

        spans ++
          [
            Span.new(
              String.duplicate(
                " ",
                max(width - display_width(Enum.map_join(spans, & &1.content)), 0)
              )
            )
          ]
      end)
      |> Enum.intersperse([Span.new(" │ ", style: %Style{fg: @muted})])
      |> List.flatten()

    Line.new(spans)
  end

  defp display_width(text) do
    glyphs = String.graphemes(text)
    widths = Alto.TUI.Selection.glyph_widths(glyphs)
    Enum.reduce(glyphs, 0, &(Map.get(widths, &1, 1) + &2))
  end

  defp wrap_code(line, width) do
    glyphs =
      Enum.flat_map(line.spans, fn span ->
        span.content
        |> String.replace("\n", "")
        |> String.replace("\t", "    ")
        |> String.graphemes()
        |> Enum.map(&{&1, span.style})
      end)

    widths = Alto.TUI.Selection.glyph_widths(Enum.map(glyphs, &elem(&1, 0)))

    {rows, spans, _} =
      Enum.reduce(glyphs, {[], [], 0}, fn {glyph, style}, {rows, spans, col} ->
        size = Map.get(widths, glyph, 1)

        if col + size > width and spans != [],
          do: {[Line.new(Enum.reverse(spans)) | rows], [Span.new(glyph, style: style)], size},
          else: {rows, [Span.new(glyph, style: style) | spans], col + size}
      end)

    Enum.reverse([Line.new(Enum.reverse(spans)) | rows])
  end

  # Parse/format only an individual block. Export compact styled runs once;
  # pointer motion and ordinary paints use the cached rows, never this path.
  defp native("", _), do: [Line.new([])]

  defp native(text, width) do
    key = {__MODULE__, :inline}
    cache = Process.get(key, %{})
    id = {text, width}

    case Map.fetch(cache, id) do
      {:ok, rows} ->
        rows

      :error ->
        rows = native_uncached(text, width)
        cache = if map_size(cache) >= 1024, do: %{}, else: cache
        if byte_size(text) <= 4096, do: Process.put(key, Map.put(cache, id, rows))
        rows
    end
  end

  defp native_uncached(text, width) do
    marker =
      Enum.find_value(0xE000..0xF8FF, fn n ->
        char = <<n::utf8>>
        if not String.contains?(text, char), do: char
      end)

    height = min(64, length(String.split(text, "\n")) + div(2 * byte_size(text), width) + 4)
    session = CellSession.new(width, height)

    try do
      native_pages(session, text <> "\n\n" <> marker, marker, width, height, 0, [])
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.reverse()
      |> Enum.drop_while(&blank?/1)
      |> Enum.reverse()
    after
      CellSession.close(session)
    end
  end

  defp native_pages(session, text, marker, width, height, offset, acc) do
    :ok = CellSession.draw(session, [])

    :ok =
      CellSession.draw(session, [
        {%NativeMarkdown{content: text, scroll: {offset, 0}, style: %Style{fg: :white}},
         %Rect{width: width, height: height}}
      ])

    cells = CellSession.take_cells(session).cells |> Enum.chunk_every(width)

    case Enum.find_index(cells, fn row -> Enum.any?(row, &(&1.symbol == marker)) end) do
      nil when offset < 65_000 ->
        native_pages(session, text, marker, width, height, offset + height, [
          styled_rows(cells) | acc
        ])

      nil ->
        [styled_rows(cells) | acc]

      row ->
        [styled_rows(Enum.take(cells, row)) | acc]
    end
  end

  defp styled_rows(rows) do
    glyphs = rows |> List.flatten() |> Enum.map(& &1.symbol)
    widths = Alto.TUI.Selection.glyph_widths(glyphs)

    Enum.map(rows, fn cells ->
      {spans, _} =
        Enum.reduce(cells, {[], 0}, fn cell, {spans, next} ->
          if cell.col < next do
            {spans, next}
          else
            style = %Style{
              fg: cell.fg,
              bg: if(cell.bg == :reset, do: nil, else: cell.bg),
              modifiers: cell.modifiers
            }

            next = cell.col + Map.get(widths, cell.symbol, 1)

            case spans do
              [%Span{style: ^style} = span | rest] ->
                {[%{span | content: span.content <> cell.symbol} | rest], next}

              _ ->
                {[Span.new(cell.symbol, style: style) | spans], next}
            end
          end
        end)

      spans = Enum.reverse(spans)
      # Native row padding is not content and would interfere with table widths.
      spans = trim_padding(Enum.reverse(spans)) |> Enum.reverse()
      Line.new(spans)
    end)
  end

  defp trim_padding([]), do: []

  defp trim_padding([span | rest]) do
    text = String.trim_trailing(span.content)
    if text == "", do: trim_padding(rest), else: [%{span | content: text} | rest]
  end

  defp blank?(line), do: Enum.all?(line.spans, &(String.trim(&1.content) == ""))
end
