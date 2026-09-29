defmodule Alto.TUI.Markdown do
  @moduledoc "Streaming-safe native Markdown with tables rendered as labeled records."

  alias ExRatatui.{CellSession, Style, Text}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{CodeBlock, Markdown}

  @muted {:rgb, 150, 160, 175}

  def render(source, width) do
    width = max(width, 1)

    groups =
      source
      |> String.split("\n")
      |> blocks([])
      |> Enum.map(&cached_block(&1, width))

    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten())
  end

  @doc "Render the final visible blocks without materializing earlier Markdown."
  def tail(source, width, height) do
    width = max(width, 1)

    {groups, _} =
      source
      |> String.split("\n")
      |> blocks([])
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn block, {groups, count} ->
        rows = cached_block(block, width)
        count = count + length(rows) + if(groups == [], do: 0, else: 1)
        result = {[rows | groups], count}
        if count >= height, do: {:halt, result}, else: {:cont, result}
      end)

    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten() |> Enum.take(-height))
  end

  defp cached_block(block, width),
    do:
      Alto.TUI.Cache.fetch({__MODULE__, :blocks}, {width, block}, 256, fn ->
        render_block(block, width)
      end)

  @doc "Count native wrapped rows without exporting a grid of styled cells."
  def layout(source, width) do
    Alto.TUI.Cache.fetch({__MODULE__, :layouts}, {source, max(width, 1)}, 256, fn ->
      {parts, rows} =
        source
        |> String.split("\n")
        |> blocks([])
        |> expand_tables()
        |> Enum.map_reduce(0, fn block, offset ->
          plain = block_plain(block, max(width, 1))
          count = length(plain)
          {{block, offset, count, plain}, offset + count + 1}
        end)

      %{parts: parts, rows: max(rows - 1, 0), width: max(width, 1)}
    end)
  end

  @doc "Materialize just a range of an indexed Markdown document."
  def window(plan, offset, height) do
    last = min(offset + height, plan.rows)

    if last <= offset do
      []
    else
      rows =
        Enum.reduce(plan.parts, %{}, fn {block, first, count, _plain}, acc ->
          start = max(offset, first)
          stop = min(last, first + count)

          if stop > start do
            block_window(block, plan.width, start - first, stop - start)
            |> Enum.with_index(start)
            |> Enum.reduce(acc, fn {row, n}, acc -> Map.put(acc, n, row) end)
          else
            acc
          end
        end)

      Enum.map(offset..(last - 1), &Map.get(rows, &1, Line.new([])))
    end
  end

  defp expand_tables(parts) do
    Enum.flat_map(parts, fn
      {:table, headers, records} ->
        columns = Enum.reduce(records, length(headers), &max(length(&1), &2))
        headers = headers ++ Enum.map((length(headers) + 1)..columns//1, &"Column #{&1}")

        if(records == [], do: [[]], else: records)
        |> Enum.map(fn row ->
          {:markdown,
           headers
           |> Enum.with_index()
           |> Enum.map_join("\n\n", fn {header, i} -> "**#{header}:** #{Enum.at(row, i, "")}" end)}
        end)

      part ->
        [part]
    end)
  end

  def plain_rows(plan),
    do:
      plan.parts
      |> Enum.map(fn {_, _, _, plain} -> plain end)
      |> Enum.intersperse([""])
      |> List.flatten()

  defp block_plain({:code, language, _} = block, width),
    do: ["  " <> if(language == "", do: "code", else: language) | native_plain(block, width)]

  defp block_plain({:heading, text}, width), do: native_plain({:markdown, text}, width)
  defp block_plain(block, width), do: native_plain(block, width)

  defp native_plain({_kind, ""}, _width), do: [""]
  defp native_plain({:code, _, ""}, _width), do: [""]

  defp native_plain(block, width) do
    marker = marker(block)
    source = content_source(block) <> "\n\n" <> marker
    estimate = length(String.split(source, "\n")) + div(2 * byte_size(source), width) + 4
    height = min(max(div(32_768, width), 1), max(estimate, 1))
    terminal = Alto.TUI.Viewport.test_terminal(:markdown_metrics, width, height)
    measure_pages(terminal, block, source, marker, width, height, 0, 0, [])
  end

  defp measure_pages(terminal, block, source, marker, width, height, offset, last, pages) do
    :ok = ExRatatui.draw(terminal, [])

    :ok =
      ExRatatui.draw(terminal, [
        {native_widget(block, source, offset), %Rect{width: width, height: height}}
      ])

    lines = ExRatatui.get_buffer_content(terminal) |> String.split("\n")
    marker_row = Enum.find_index(lines, &String.contains?(&1, marker))
    body = if marker_row, do: Enum.take(lines, marker_row), else: lines

    last =
      Enum.with_index(body, offset)
      |> Enum.reduce(last, fn {line, n}, acc ->
        if String.trim(line) == "", do: acc, else: n + 1
      end)

    pages = [body | pages]

    if marker_row != nil or offset >= 65_000 do
      pages
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.take(last)
      |> Enum.map(&(Alto.TUI.Selection.buffer_row_text(&1, width) |> String.trim_trailing()))
    else
      measure_pages(terminal, block, source, marker, width, height, offset + height, last, pages)
    end
  end

  defp block_window({:code, language, _} = block, width, offset, height) do
    label =
      Line.new([
        Span.new("  " <> if(language == "", do: "code", else: language),
          style: %Style{fg: @muted}
        )
      ])

    if offset == 0,
      do: [label | native_window(block, width, 0, height - 1)],
      else: native_window(block, width, offset - 1, height)
  end

  defp block_window({:heading, text}, width, offset, height) do
    native_window({:markdown, text}, width, offset, height)
    |> Enum.map(fn line ->
      %{
        line
        | spans:
            Enum.map(line.spans, fn span ->
              %{
                span
                | style: %{
                    span.style
                    | modifiers: Enum.uniq([:bold | span.style.modifiers || []])
                  }
              }
            end)
      }
    end)
  end

  defp block_window(block, width, offset, height), do: native_window(block, width, offset, height)

  defp native_window(_, _, _, height) when height <= 0, do: []

  defp native_window(block, width, offset, height) do
    session = CellSession.new(width, height)

    try do
      :ok =
        CellSession.draw(session, [
          {native_widget(block, content_source(block), offset),
           %Rect{width: width, height: height}}
        ])

      CellSession.take_cells(session).cells |> Enum.chunk_every(width) |> styled_rows()
    after
      CellSession.close(session)
    end
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

      heading = heading(line) ->
        blocks(rest, [{:heading, heading} | acc])

      setext?(rest) ->
        blocks(tl(rest), [{:heading, line} | acc])

      indented?(line) ->
        {code, rest} = Enum.split_while([line | rest], &(indented?(&1) or String.trim(&1) == ""))

        code =
          code
          |> Enum.map(&Regex.replace(~r/^(?: {4}|\t)/, &1, ""))
          |> Enum.join("\n")
          |> String.trim_trailing("\n")

        blocks(rest, [{:code, "", code} | acc])

      table?(line, rest) ->
        [_separator | rest] = rest
        {rows, rest} = Enum.split_while(rest, &table_row?/1)
        blocks(rest, [{:table, cells(line), Enum.map(rows, &cells/1)} | acc])

      true ->
        {markdown, rest} = take_markdown(rest, [line])
        blocks(rest, [{:markdown, Enum.join(markdown, "\n")} | acc])
    end
  end

  defp take_markdown([], acc), do: {Enum.reverse(acc), []}

  defp take_markdown([line | rest] = remaining, acc) do
    if String.trim(line) == "" or not is_nil(fence(line)) or table?(line, rest) or
         not is_nil(heading(line)) or setext?(rest),
       do: {Enum.reverse(acc), remaining},
       else: take_markdown(rest, [line | acc])
  end

  defp heading(line) do
    case Regex.run(~r/^ {0,3}\#{1,6}(?:[ \t]+(.*)|$)/u, line) do
      [_, title] -> Regex.replace(~r/[ \t]+\#+[ \t]*$/, title, "")
      [_] -> ""
      _ -> nil
    end
  end

  defp setext?([line | _]), do: Regex.match?(~r/^ {0,3}(?:=+|-+)[ \t]*$/, line)
  defp setext?(_), do: false

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

  defp render_block({:heading, source}, width) do
    materialize({:markdown, source}, width)
    |> Enum.map(fn line ->
      %{
        line
        | spans:
            Enum.map(line.spans, fn span ->
              style = span.style || %Style{}
              %{span | style: %{style | modifiers: Enum.uniq([:bold | style.modifiers || []])}}
            end)
      }
    end)
  end

  defp render_block({:markdown, source}, width), do: materialize({:markdown, source}, width)

  defp render_block({:code, language, code}, width) do
    label = if language == "", do: "code", else: language

    [
      Line.new([Span.new("  " <> label, style: %Style{fg: @muted})])
      | materialize({:code, language, code}, width)
    ]
  end

  defp render_block({:table, headers, records}, width) do
    columns = Enum.reduce(records, length(headers), &max(length(&1), &2))
    headers = headers ++ Enum.map((length(headers) + 1)..columns//1, &"Column #{&1}")
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
