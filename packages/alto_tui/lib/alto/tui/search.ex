defmodule Alto.TUI.Search do
  @moduledoc "Transient literal conversation search, independent of sessions and agent input."
  alias Alto.TUI.{State, Transcript}
  alias ExRatatui.{Style, Text}
  alias ExRatatui.Text.{Line, Span}

  def open(%{search: search} = state) when not is_nil(search), do: state

  def open(state) do
    search = %{
      input: ExRatatui.text_input_new(),
      index: 0,
      return_state:
        Map.take(state, [
          :focus,
          :details_visible?,
          :details_return_focus,
          :details_drawer_auto_opened?
        ])
    }

    state =
      if state.details_return_focus && state.pending_approvals == [],
        do: State.close_details_drawer(state),
        else: state

    %{
      state
      | search: search,
        details_visible?: true,
        leader?: false,
        selection: Alto.TUI.Selection.new()
    }
  end

  def close(%{search: nil} = state), do: state

  def close(state) do
    state
    |> Map.merge(state.search.return_state)
    |> Map.merge(%{search: nil, selection: Alto.TUI.Selection.new()})
    |> State.reconcile_responsive_focus()
  end

  def query(%{search: nil}), do: ""
  def query(state), do: ExRatatui.text_input_get_value(state.search.input)

  def edit(state, code) do
    before = query(state)

    if code == :clear,
      do: ExRatatui.text_input_set_value(state.search.input, ""),
      else: ExRatatui.text_input_handle_key(state.search.input, code)

    if query(state) == before, do: state, else: changed(state)
  end

  def paste(state, text) do
    ExRatatui.text_input_insert_str(state.search.input, String.replace(text, ["\r", "\n"], " "))
    changed(state)
  end

  defp changed(state) do
    if byte_size(query(state)) > 512,
      do: ExRatatui.text_input_set_value(state.search.input, Alto.Text.prefix(query(state), 512))

    %{state | search: %{state.search | index: 0}, selection: Alto.TUI.Selection.new()}
  end

  def matches(state), do: find(State.visible_entries(state), query(state))

  def find(_entries, ""), do: []

  def find(entries, query) do
    cached(:matches, {entries, query}, fn ->
      regex = Regex.compile!(Regex.escape(query), "iu")

      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        source = source(entry)

        Regex.scan(regex, source, return: :index)
        |> Enum.with_index()
        |> Enum.map(fn {[{start, size}], occurrence} ->
          before =
            binary_part(source, max(start - 160, 0), min(start, 160))
            |> valid_suffix()
            |> String.split("\n")
            |> List.last()
            |> String.slice(-40, 40)

          hit = binary_part(source, start, size)

          tail =
            binary_part(source, start + size, byte_size(source) - start - size)
            |> Alto.Text.prefix(400)
            |> String.split("\n")
            |> hd()
            |> String.slice(0, 100)

          %{
            entry: index,
            start: start,
            size: size,
            occurrence: occurrence,
            kind: to_string(entry[:kind] || "message"),
            before: before,
            hit: hit,
            after: tail
          }
        end)
      end)
    end)
  end

  # The bounded prefix window may start inside a UTF-8 codepoint.
  defp valid_suffix(text) do
    if String.valid?(text) do
      text
    else
      <<_, rest::binary>> = text
      valid_suffix(rest)
    end
  end

  defp source(%{kind: kind, text: text})
       when kind in [:assistant, :codex_assistant] and is_binary(text),
       do: text

  defp source(entry), do: Transcript.text(entry)

  def index(state, matches), do: min(state.search.index, max(length(matches) - 1, 0))

  def count(state) do
    matches = matches(state)
    "#{if matches == [], do: 0, else: index(state, matches) + 1}/#{length(matches)}"
  end

  def move(state, delta) do
    matches = matches(state)

    selected =
      if matches == [], do: 0, else: Integer.mod(index(state, matches) + delta, length(matches))

    select(state, selected)
  end

  def select(state, index),
    do: %{
      state
      | search: %{state.search | index: max(index, 0)},
        selection: Alto.TUI.Selection.new()
    }

  # Match counts come from original entry text, never viewport wrapping. Locate
  # the corresponding visible occurrence across styled spans and soft wraps.
  # Markdown syntax with no visible glyph still has an exact source excerpt in
  # the results list and navigates to its containing entry.
  def projection(state, width) do
    entries = State.visible_entries(state)
    query = query(state)

    cached(:projection, {entries, query, width}, fn ->
      document = Transcript.document(entries, width)
      matches = find(entries, query)
      wrapped = wrapped_pattern(query)

      {positions, _} =
        Enum.map_reduce(Enum.zip(document.groups, entries), 0, fn {lines, entry}, row ->
          assistant? = entry[:kind] in [:assistant, :codex_assistant]
          body = if assistant?, do: Enum.drop(lines, 1), else: lines
          mapping = source_rows(body, source(entry), row + if(assistant?, do: 1, else: 0))
          text = Enum.map_join(body, "\n", &line_text/1)
          offsets = if wrapped, do: Regex.scan(wrapped, text, return: :index), else: []

          {{row + if(assistant?, do: 1, else: 0), text, offsets, mapping},
           row + length(lines) + 1}
        end)

      positions = List.to_tuple(positions)

      matches =
        Enum.map(matches, fn match ->
          {row, text, offsets, mapping} = elem(positions, match.entry)

          case if(mapping,
                 do: {:mapped, source_ranges(mapping, match)},
                 else: Enum.at(offsets, match.occurrence)
               ) do
            {:mapped, [{first_row, _, _} | _] = ranges} ->
              Map.merge(match, %{row: first_row, ranges: ranges})

            [{start, size}] ->
              prefix = binary_part(text, 0, start)
              first_row = row + length(String.split(prefix, "\n")) - 1
              first_col = byte_size(List.last(String.split(prefix, "\n")))
              parts = binary_part(text, start, size) |> String.split("\n")

              ranges =
                Enum.with_index(parts, fn part, i ->
                  {first_row + i, if(i == 0, do: first_col, else: 0), byte_size(part)}
                end)

              Map.merge(match, %{row: first_row, ranges: ranges})

            _ ->
              Map.merge(match, %{row: row, ranges: []})
          end
        end)

      %{text: document.text, matches: matches}
    end)
  end

  # Literal rows can be bound directly to source bytes. This distinguishes a
  # soft wrap from a real newline, even when the same text occurs on both sides.
  defp source_rows(lines, source, first_row) do
    Enum.with_index(lines, first_row)
    |> Enum.reduce_while({[], 0}, fn {line, row}, {rows, cursor} ->
      text = line_text(line)

      cond do
        text == "" ->
          {:cont, {rows, cursor}}

        true ->
          case :binary.match(source, text, scope: {cursor, byte_size(source) - cursor}) do
            {start, size} -> {:cont, {[{row, start, size} | rows], start + size}}
            :nomatch -> {:halt, nil}
          end
      end
    end)
    |> case do
      {rows, _} -> Enum.reverse(rows)
      nil -> nil
    end
  end

  defp source_ranges(rows, match) do
    Enum.flat_map(rows, fn {row, start, size} ->
      first = max(start, match.start)
      last = min(start + size, match.start + match.size)
      if first < last, do: [{row, first - start, last - first}], else: []
    end)
  end

  defp wrapped_pattern(""), do: nil

  defp wrapped_pattern(query) do
    query
    |> String.codepoints()
    |> Enum.map_join("(?:\n *)?", fn
      " " -> "(?: |\n *)"
      char -> Regex.escape(char)
    end)
    |> Regex.compile!("iu")
  end

  def target_row(state, width) do
    data = projection(state, width)

    case Enum.at(data.matches, index(state, data.matches)) do
      nil -> nil
      match -> match.row
    end
  end

  def highlighted(state, width) do
    data = projection(state, width)
    selected = index(state, data.matches)

    cached(:highlight, {data, selected}, fn ->
      ranges =
        data.matches
        |> Enum.with_index()
        |> Enum.flat_map(fn {match, i} ->
          Enum.map(match.ranges, fn {row, col, size} -> {row, {col, size, i == selected}} end)
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      %Text{
        data.text
        | lines:
            Enum.with_index(data.text.lines, fn line, row ->
              highlight_line(line, Map.get(ranges, row, []))
            end)
      }
    end)
  end

  defp highlight_line(line, []), do: line

  defp highlight_line(line, ranges) do
    {spans, _} =
      Enum.map_reduce(line.spans, 0, fn span, offset ->
        last = offset + byte_size(span.content)

        boundaries =
          [offset, last | Enum.flat_map(ranges, fn {start, size, _} -> [start, start + size] end)]
          |> Enum.filter(&(&1 >= offset and &1 <= last))
          |> Enum.uniq()
          |> Enum.sort()

        parts =
          boundaries
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [start, stop] ->
            style =
              case Enum.find(ranges, fn {pos, size, _} -> start >= pos and start < pos + size end) do
                {_, _, selected} -> match_style(selected)
                nil -> span.style
              end

            Span.new(binary_part(span.content, start - offset, stop - start), style: style)
          end)

        {parts, last}
      end)

    %{line | spans: List.flatten(spans)}
  end

  def result_line(match, number, width) do
    before = String.slice(match.before, -max(div(width - 20, 3), 1), max(div(width - 20, 3), 1))

    Line.new([
      Span.new("#{number + 1} · #{match.kind} › " <> before),
      Span.new(match.hit, style: match_style(false)),
      Span.new(match.after)
    ])
  end

  defp match_style(selected),
    do: %Style{fg: :black, bg: if(selected, do: :light_cyan, else: :yellow)}

  defp line_text(line), do: line.spans |> Enum.map_join(& &1.content) |> String.trim_trailing()

  defp cached(key, input, fun) do
    key = {__MODULE__, key}

    case Process.get(key) do
      {^input, result} ->
        result

      _ ->
        result = fun.()
        Process.put(key, {input, result})
        result
    end
  end
end
