defmodule Alto.TUI.Search do
  @moduledoc "Transient literal conversation search, independent of sessions and agent input."
  alias Alto.TUI.{State, Transcript}
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  @max_matches 1000

  def clear_cache, do: Alto.TUI.Cache.drop_namespace(__MODULE__)

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
    clear_cache()

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

  def find(entries, query), do: match_data(entries, query).matches

  defp match_data(entries, query) do
    cached(:matches, {entries, query}, fn ->
      regex = Regex.compile!(Regex.escape(query), "iu")

      {matches, _} =
        Enum.reduce_while(Enum.with_index(entries), {[], 0}, fn {entry, index}, {acc, count} ->
          source = source(entry)
          offsets = scan(regex, source, @max_matches + 1 - count)

          found =
            Enum.with_index(offsets, fn [{start, size}], occurrence ->
              %{
                entry: index,
                start: start,
                size: size,
                occurrence: occurrence,
                kind: to_string(entry[:kind] || "message"),
                hit: Alto.Retained.detach(binary_part(source, start, size))
              }
            end)

          next = {acc ++ found, count + length(found)}
          if elem(next, 1) > @max_matches, do: {:halt, next}, else: {:cont, next}
        end)

      %{matches: Enum.take(matches, @max_matches), truncated: length(matches) > @max_matches}
    end)
  end

  # Regex.run with an offset keeps both the temporary scan and retained result
  # bounded. Literal queries are nonempty, so every match advances.
  defp scan(regex, source, limit), do: scan(regex, source, limit, 0, [])
  defp scan(_, _, 0, _, acc), do: Enum.reverse(acc)

  defp scan(regex, source, limit, offset, acc) do
    case Regex.run(regex, source, return: :index, offset: offset) do
      [{start, size}] = hit when size > 0 ->
        scan(regex, source, limit - 1, start + size, [hit | acc])

      _ ->
        Enum.reverse(acc)
    end
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
       when kind in [:assistant, :codex_assistant, :reasoning] and is_binary(text),
       do: text

  defp source(entry), do: Transcript.text(entry, expanded: true)

  def index(state, matches), do: min(state.search.index, max(length(matches) - 1, 0))

  def count(state) do
    matches = matches(state)

    suffix =
      if query(state) != "" and match_data(State.visible_entries(state), query(state)).truncated,
        do: "+",
        else: ""

    "#{if matches == [], do: 0, else: index(state, matches) + 1}/#{length(matches)}#{suffix}"
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
      layout = Transcript.index(entries, width, expanded: true)
      document = %{groups: Transcript.plain_groups(layout)}
      matches = find(entries, query)
      wrapped = wrapped_pattern(query)

      {positions, _} =
        Enum.map_reduce(Enum.zip(document.groups, entries), 0, fn {lines, entry}, row ->
          assistant? = entry[:kind] in [:assistant, :codex_assistant, :reasoning]
          body = if assistant?, do: Enum.drop(lines, 1), else: lines
          mapping = source_rows(body, source(entry), row + if(assistant?, do: 1, else: 0))
          text = Enum.map_join(body, "\n", &line_text/1)
          offsets = if wrapped, do: scan(wrapped, text, @max_matches), else: []

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

      %{layout: layout, matches: matches}
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

  def highlighted(state, width, offset \\ 0, height \\ :all) do
    data = projection(state, width)
    selected = index(state, data.matches)

    height = if height == :all, do: max(data.layout.rows, 1), else: height

    cached(:highlight, {data, selected, offset, height}, fn ->
      text =
        Transcript.viewport(State.visible_entries(state), width, offset, height, expanded: true)

      ranges =
        data.matches
        |> Enum.with_index()
        |> Enum.flat_map(fn {match, i} ->
          Enum.map(match.ranges, fn {row, col, size} -> {row, {col, size, i == selected}} end)
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      %{
        text
        | lines:
            Enum.with_index(text.lines, text.offset)
            |> Enum.map(fn {line, row} ->
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

  def result_line(match, number, width, entries) do
    source = source(Enum.at(entries, match.entry))

    before =
      binary_part(source, max(match.start - 160, 0), min(match.start, 160))
      |> valid_suffix()
      |> String.split("\n")
      |> List.last()
      |> String.slice(-40, 40)

    tail =
      binary_part(source, match.start + match.size, byte_size(source) - match.start - match.size)
      |> Alto.Text.prefix(400)
      |> String.split("\n")
      |> hd()
      |> String.slice(0, 100)

    before = String.slice(before, -max(div(width - 20, 3), 1), max(div(width - 20, 3), 1))

    Line.new([
      Span.new("#{number + 1} · #{match.kind} › " <> before),
      Span.new(match.hit, style: match_style(false)),
      Span.new(tail)
    ])
  end

  defp match_style(selected),
    do: %Style{fg: :black, bg: if(selected, do: :light_cyan, else: :yellow)}

  defp line_text(line), do: line.spans |> Enum.map_join(& &1.content) |> String.trim_trailing()

  defp cached(key, input, fun),
    do: Alto.TUI.Cache.fetch({__MODULE__, key}, input, 1, fun)
end
