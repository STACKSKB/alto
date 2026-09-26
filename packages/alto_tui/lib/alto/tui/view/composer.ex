defmodule Alto.TUI.View.Composer do
  @moduledoc "Code and wrapped-prose projection from explicit editing, geometry and style inputs."
  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Paragraph, Textarea}

  def widget(%{mode: :code} = context), do: native_composer(context)
  def widget(context), do: wrapped_composer(context)

  defp native_composer(context) do
    %Textarea{
      state: context.textarea,
      placeholder: "Paste or type code…",
      placeholder_style: context.styles.muted,
      style: context.styles.body,
      cursor_style: context.styles.cursor,
      cursor_line_style: context.styles.cursor_line,
      block: context.block
    }
  end

  # ExRatatui 0.13's stateful textarea does not expose soft wrapping. Prose mode
  # therefore renders a wrapped, cursor-aware projection while retaining that
  # textarea as the sole editing state. Code mode above uses the native widget.
  defp wrapped_composer(context) do
    value = ExRatatui.textarea_get_value(context.textarea)
    {cursor_line, cursor_column} = ExRatatui.textarea_cursor(context.textarea)
    {text, cursor_row} = wrapped_composer_text(context, value, cursor_line, cursor_column)
    {_width, height} = context.size
    scroll_y = if cursor_row, do: max(cursor_row - height + 1, 0), else: 0

    %Paragraph{
      text: text,
      wrap: false,
      scroll: {scroll_y, 0},
      style: context.styles.body,
      block: context.block
    }
  end

  defp wrapped_composer_text(context, "", _cursor_line, _cursor_column) do
    spans =
      if context.focused? do
        [
          Span.new(" ", style: context.styles.cursor),
          Span.new("Describe the next change…", style: context.styles.muted)
        ]
      else
        [Span.new("Describe the next change…", style: context.styles.muted)]
      end

    {Text.new([Line.new(spans)]), if(context.focused?, do: 0, else: nil)}
  end

  defp wrapped_composer_text(context, value, cursor_line, cursor_column) do
    {width, _height} = context.size

    {rows, {_row_count, cursor_row}} =
      value
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.map_reduce({0, nil}, fn {line, line_index}, {start_row, found_cursor} ->
        graphemes = String.graphemes(line)
        cursor? = context.focused? and line_index == cursor_line
        column = min(cursor_column, length(graphemes))
        projections = wrap_prose_line(graphemes, width)

        projections =
          maybe_add_end_cursor_row(projections, cursor?, column, length(graphemes), width)

        {display_cursor_row, display_cursor_column} =
          if cursor?, do: cursor_projection(projections, column, width), else: {nil, nil}

        line_rows =
          projections
          |> Enum.with_index()
          |> Enum.map(fn {projection, row_index} ->
            if cursor? and row_index == display_cursor_row do
              cursor_spans(projection.graphemes, display_cursor_column, context.styles.cursor)
            else
              Line.new([Span.new(Enum.join(projection.graphemes))])
            end
          end)

        cursor_row =
          if cursor?, do: start_row + display_cursor_row, else: found_cursor

        {line_rows, {start_row + length(line_rows), cursor_row}}
      end)

    {Text.new(List.flatten(rows)), cursor_row}
  end

  defp wrap_prose_line(graphemes, width, offset \\ 0)

  defp wrap_prose_line(graphemes, width, offset) when length(graphemes) <= width,
    do: [%{graphemes: graphemes, start: offset, stop: offset + length(graphemes)}]

  defp wrap_prose_line(graphemes, width, offset) do
    window = Enum.take(graphemes, width)
    first_word = Enum.find_index(window, &(not whitespace?(&1))) || width

    break_at =
      for {grapheme, index} <- Enum.with_index(window),
          index > first_word,
          whitespace?(grapheme),
          reduce: width do
        _ -> index
      end

    consumed = if break_at < width, do: break_at + 1, else: width
    row = %{graphemes: Enum.take(window, break_at), start: offset, stop: offset + break_at}
    [row | wrap_prose_line(Enum.drop(graphemes, consumed), width, offset + consumed)]
  end

  defp maybe_add_end_cursor_row(rows, true, column, content_length, width)
       when column == content_length do
    case Elixir.List.last(rows) do
      %{graphemes: graphemes, stop: ^content_length} when length(graphemes) == width ->
        rows ++ [%{graphemes: [], start: content_length, stop: content_length}]

      _other ->
        rows
    end
  end

  defp maybe_add_end_cursor_row(rows, _cursor?, _column, _length, _width), do: rows

  defp cursor_projection(rows, column, width) do
    last_index = length(rows) - 1

    index =
      rows
      |> Enum.with_index()
      |> Enum.find_value(last_index, fn {row, index} ->
        next = Enum.at(rows, index + 1)

        cond do
          column < row.stop -> index
          column > row.stop -> nil
          is_nil(next) -> index
          next.start > row.stop -> index
          length(row.graphemes) < width -> index
          true -> nil
        end
      end)

    row = Enum.at(rows, index)
    {index, column |> Kernel.-(row.start) |> max(0) |> min(length(row.graphemes))}
  end

  defp whitespace?(grapheme), do: String.match?(grapheme, ~r/^\s$/u)

  defp cursor_spans(graphemes, column, cursor_style) do
    {before, rest} = Enum.split(graphemes, column)

    case rest do
      [cursor | trailing] ->
        Line.new([
          Span.new(Enum.join(before)),
          Span.new(cursor, style: cursor_style),
          Span.new(Enum.join(trailing))
        ])

      [] ->
        Line.new([
          Span.new(Enum.join(before)),
          Span.new(" ", style: cursor_style)
        ])
    end
  end
end
