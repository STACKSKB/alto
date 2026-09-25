defmodule Alto.TUI.Markdown do
  @moduledoc "Streaming-safe native Markdown with responsive evidence tables."

  alias ExRatatui.{CellSession, Style, Text}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{CodeBlock, Markdown}

  @muted {:rgb, 150, 160, 175}

  def render(source, width) do
    width = max(width, 1)
    key = {__MODULE__, :blocks}
    widths = Process.get(key, [])

    cache =
      case List.keyfind(widths, width, 0) do
        {^width, cache} -> cache
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

    # Streaming replaces the final block repeatedly. Retain only current blocks
    # at the three most recent pane widths.
    Process.put(key, Enum.take([{width, used} | List.keydelete(widths, width, 0)], 3))
    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten())
  end

  def plain(source, width) do
    render(source, width).lines
    |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  defp blocks([], acc), do: Enum.reverse(acc)
  defp blocks(["" | rest], acc), do: blocks(rest, acc)

  defp blocks([line | rest], acc) do
    cond do
      opening = fence(line) ->
        {code, rest} = take_code(rest, opening, [])
        blocks(rest, [{:code, elem(opening, 1), Enum.join(code, "\n")} | acc])

      indented?(line) ->
        {code, rest} = Enum.split_while([line | rest], &(indented?(&1) or String.trim(&1) == ""))

        code =
          code
          |> Enum.map(&Regex.replace(~r/^(?: {4}|\t)/, &1, ""))
          |> Enum.join("\n")
          |> String.trim_trailing("\n")

        blocks(rest, [{:code, "", code} | acc])

      table?(line, rest) ->
        [separator | rest] = rest
        {rows, rest} = Enum.split_while(rest, &table_row?/1)
        source = Enum.join([line, separator | rows], "\n")
        blocks(rest, [{:table, source, cells(line), Enum.map(rows, &cells/1)} | acc])

      true ->
        {markdown, rest} = take_markdown(rest, [line])
        blocks(rest, [{:markdown, Enum.join(markdown, "\n")} | acc])
    end
  end

  defp take_markdown([], acc), do: {Enum.reverse(acc), []}

  defp take_markdown([line | rest] = remaining, acc) do
    if String.trim(line) == "" or not is_nil(fence(line)) or table?(line, rest),
      do: {Enum.reverse(acc), remaining},
      else: take_markdown(rest, [line | acc])
  end

  defp indented?(line), do: String.starts_with?(line, ["    ", "\t"])

  defp fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      [_, marker, language] -> {marker, String.trim(language)}
      _ -> nil
    end
  end

  defp take_code([], _opening, acc), do: {Enum.reverse(acc), []}

  defp take_code([line | rest], {marker, _} = opening, acc) do
    closing = String.trim(line)

    if String.length(closing) >= String.length(marker) and
         String.trim(closing, String.first(marker)) == "",
       do: {Enum.reverse(acc), rest},
       else: take_code(rest, opening, [line | acc])
  end

  defp table?(header, [separator | _]) do
    columns = cells(separator)

    String.contains?(header, "|") and length(columns) == length(cells(header)) and
      length(columns) > 1 and Enum.all?(columns, &Regex.match?(~r/^:?-{3,}:?$/, &1))
  end

  defp table?(_, _), do: false
  defp table_row?(line), do: String.trim(line) != "" and String.contains?(line, "|")

  # Escaped pipes and pipes inside inline code belong to the cell.
  defp cells(line) do
    tokens = Regex.scan(~r/\\.|`+|[^\\`|]+|\||./us, String.trim(line)) |> List.flatten()

    {parts, current, _ticks} =
      Enum.reduce(tokens, {[], [], nil}, fn token, {parts, current, ticks} ->
        cond do
          token == "|" and ticks == nil ->
            {[current |> Enum.reverse() |> Enum.join() | parts], [], ticks}

          String.starts_with?(token, "`") ->
            {parts, [token | current], if(ticks == token, do: nil, else: ticks || token)}

          token == "\\|" ->
            {parts, ["|" | current], ticks}

          true ->
            {parts, [token | current], ticks}
        end
      end)

    result = Enum.reverse([current |> Enum.reverse() |> Enum.join() | parts])
    result = if String.starts_with?(String.trim(line), "|"), do: tl(result), else: result

    result =
      if String.ends_with?(String.trim(line), "|") and List.last(result) == "",
        do: Enum.drop(result, -1),
        else: result

    Enum.map(result, &String.trim/1)
  end

  defp render_block({:markdown, source}, width), do: materialize({:markdown, source}, width)

  defp render_block({:code, language, code}, width) do
    label = if language == "", do: "code", else: language

    [
      Line.new([Span.new("  " <> label, style: %Style{fg: @muted})])
      | materialize({:code, language, code}, width)
    ]
  end

  defp render_block({:table, source, headers, records}, width) do
    original_columns = length(headers)
    columns = Enum.reduce(records, length(headers), &max(length(&1), &2))
    headers = headers ++ Enum.map((length(headers) + 1)..columns//1, &"Column #{&1}")

    required =
      1 +
        Enum.reduce(0..(columns - 1), 0, fn index, total ->
          widest =
            Enum.reduce([headers | records], 1, fn row, size ->
              max(size, display_width(Enum.at(row, index, "")))
            end)

          total + widest + 3
        end)

    # The native GFM parser treats pipes in code spans as separators. It also
    # discards cells beyond the header width, so use the semantic fallback for
    # either case rather than losing evidence.
    native_safe? =
      Enum.all?([headers | records], fn row ->
        length(row) <= original_columns and Enum.all?(row, &(not String.contains?(&1, "|")))
      end)

    if required <= width and native_safe? do
      materialize({:markdown, source}, width)
    else
      rows = if records == [], do: [[]], else: records

      rows
      |> Enum.map(fn row ->
        headers
        |> Enum.with_index()
        |> Enum.map_join("\n\n", fn {header, index} ->
          "**#{header}:** #{Enum.at(row, index, "")}"
        end)
      end)
      |> Enum.map(&materialize({:markdown, &1}, width))
      |> Enum.intersperse([Line.new([])])
      |> List.flatten()
    end
  end

  defp display_width(text) do
    glyphs = String.graphemes(text)
    widths = Alto.TUI.Selection.glyph_widths(glyphs)
    Enum.reduce(glyphs, 0, &(Map.get(widths, &1, 1) + &2))
  end

  defp materialize({_kind, ""}, _width), do: [Line.new([])]
  defp materialize({:code, _language, ""}, _width), do: [Line.new([])]

  defp materialize(content, width) do
    marker = marker(content)
    source = content_source(content) <> "\n\n" <> marker
    height = min(64, length(String.split(source, "\n")) + div(2 * byte_size(source), width) + 4)
    session = CellSession.new(width, height)

    try do
      native_pages(session, content, source, marker, width, height, 0, [])
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.reverse()
      |> Enum.drop_while(&blank?/1)
      |> Enum.reverse()
    after
      CellSession.close(session)
    end
  end

  defp native_pages(session, content, source, marker, width, height, offset, acc) do
    :ok = CellSession.draw(session, [])
    widget = native_widget(content, source, offset)
    :ok = CellSession.draw(session, [{widget, %Rect{width: width, height: height}}])
    cells = CellSession.take_cells(session).cells |> Enum.chunk_every(width)

    case Enum.find_index(cells, fn row -> Enum.any?(row, &(&1.symbol == marker)) end) do
      nil when offset < 65_000 ->
        native_pages(session, content, source, marker, width, height, offset + height, [
          styled_rows(cells) | acc
        ])

      nil ->
        [styled_rows(cells) | acc]

      row ->
        [styled_rows(Enum.take(cells, row)) | acc]
    end
  end

  defp native_widget({:markdown, _}, source, offset),
    do: %Markdown{content: source, scroll: {offset, 0}, style: %Style{fg: :white}}

  defp native_widget({:code, language, _}, source, offset),
    do: %CodeBlock{
      content: source,
      language: if(language == "", do: nil, else: language),
      scroll: {offset, 0},
      wrap: true
    }

  # Transcript lines are meaningful during streaming; Markdown soft breaks
  # would otherwise collapse long line-oriented output into one visual row.
  defp content_source({:markdown, source}), do: String.replace(source, "\n", "  \n")
  defp content_source({:code, _language, source}), do: String.replace(source, "\t", "    ")

  defp marker(content) do
    source = content_source(content)

    Enum.find_value(0xE000..0xF8FF, fn point ->
      char = <<point::utf8>>
      if not String.contains?(source, char), do: char
    end)
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

      Line.new(trim_padding(Enum.reverse(spans)))
    end)
  end

  defp trim_padding(spans) do
    spans
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1.content) == ""))
    |> case do
      [] ->
        []

      [span | rest] ->
        Enum.reverse([%{span | content: String.trim_trailing(span.content)} | rest])
    end
  end

  defp blank?(line), do: Enum.all?(line.spans, &(String.trim(&1.content) == ""))
end
