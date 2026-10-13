defmodule Alto.TUI.Viewport do
  @moduledoc "Cache native word wrapping in chunks and paint only visible paragraph rows."
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Alto.TUI.SelectionRegions

  def widgets(widgets) do
    Enum.map(widgets, fn
      {%Paragraph{text: %Alto.TUI.Window{} = window, scroll: {offset, horizontal}} = widget, rect} ->
        inner = SelectionRegions.content_rect(widget, rect)
        lines = Enum.slice(window.lines, max(offset - window.offset, 0), max(inner.height, 0))
        {%{widget | text: ExRatatui.Text.new(lines), wrap: false, scroll: {0, horizontal}}, rect}

      {%Paragraph{text: %ExRatatui.Text{lines: lines} = text, wrap: false, scroll: {offset, 0}} =
           widget, rect} ->
        inner = SelectionRegions.content_rect(widget, rect)

        {%{
           widget
           | text: %{text | lines: Enum.slice(lines, offset, max(inner.height, 0))},
             scroll: {0, 0}
         }, rect}

      {%Paragraph{text: text, wrap: false, scroll: {offset, horizontal}} = widget, rect}
      when is_binary(text) and byte_size(text) > 4096 ->
        inner = SelectionRegions.content_rect(widget, rect)
        visible = text |> String.split("\n") |> Enum.slice(offset, max(inner.height, 0))
        {%{widget | text: Enum.join(visible, "\n"), scroll: {0, horizontal}}, rect}

      {%Paragraph{text: text, wrap: true, scroll: {offset, 0}, alignment: :left} = widget, rect}
      when is_binary(text) and byte_size(text) > 4096 ->
        inner = SelectionRegions.content_rect(widget, rect)
        rows = rows(text, max(inner.width, 1))
        visible = slice(rows, offset, inner.height)
        {%{widget | text: visible, wrap: false, scroll: {0, 0}}, rect}

      other ->
        other
    end)
  end

  def bottom(%ExRatatui.Text{lines: lines}, _width, height),
    do: max(length(lines) - max(height, 1), 0)

  def bottom(%Alto.TUI.Window{rows: rows}, _width, height),
    do: max(rows - max(height, 1), 0)

  def bottom(text, width, height),
    do:
      max(
        tuple_size(rows(String.trim_trailing(text), max(width, 1))) - max(height, 1),
        0
      )

  def rows(text, width) do
    Alto.TUI.Cache.fetch({__MODULE__, :documents}, {text, width}, 4, fn ->
      text
      |> String.split("\n", trim: false)
      |> Enum.chunk_every(128)
      |> Enum.flat_map(fn lines ->
        chunk = Enum.join(lines, "\n")

        Alto.TUI.Cache.fetch({__MODULE__, :chunks}, {width, chunk}, 512, fn ->
          fits = &(byte_size(&1) <= width and not Regex.match?(~r/[^\x20-\x7E]/, &1))

          lines
          |> Enum.chunk_by(fits)
          |> Enum.flat_map(fn [first | _] = group ->
            if fits.(first),
              do: Enum.map(group, &String.trim_leading(&1, " ")),
              else: wrap(Enum.join(group, "\n"), width)
          end)
        end)
      end)
      |> List.to_tuple()
    end)
  end

  defp slice(rows, offset, height) do
    last = min(offset + height, tuple_size(rows)) - 1
    if offset <= last, do: Enum.map_join(offset..last, "\n", &elem(rows, &1)), else: ""
  end

  defp wrap(text, width) do
    marker = marker(text)
    source = text <> "\n" <> marker
    height = min(256, length(String.split(text, "\n")) + div(2 * byte_size(text), width) + 3)
    terminal = test_terminal(:wrap, width, height)

    render_pages(
      height,
      fn offset ->
        :ok = ExRatatui.draw(terminal, [])

        :ok =
          ExRatatui.draw(terminal, [
            {%Paragraph{text: source, wrap: true, scroll: {offset, 0}},
             %Rect{width: width, height: height}}
          ])

        terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
      end,
      &(&1 == marker),
      fn rows -> Enum.map(rows, &Alto.TUI.Selection.buffer_row_text(&1, width)) end
    )
  end

  @doc false
  def marker(source) do
    Enum.find_value(0xE000..0xF8FF, fn point ->
      char = <<point::utf8>>
      if not String.contains?(source, char), do: char
    end)
  end

  @doc false
  def render_pages(height, render, end_row?, transform) do
    Stream.iterate(0, &(&1 + height))
    |> Enum.reduce_while([], fn offset, pages ->
      rows = render.(offset)
      stop = Enum.find_index(rows, end_row?)
      pages = [transform.(Enum.take(rows, stop || length(rows))) | pages]

      # Native scroll offsets are unsigned 16-bit values.
      if stop != nil or offset + height > 65_535,
        do: {:halt, pages |> Enum.reverse() |> Enum.concat()},
        else: {:cont, pages}
    end)
  end

  @doc false
  def test_terminal(owner, width, height) do
    key = {__MODULE__, :terminal, owner}

    case Process.get(key) do
      {^width, ^height, terminal} ->
        terminal

      previous ->
        # Native grids can dwarf the BEAM resource handle. Release a replaced
        # scratch grid now instead of waiting for heap pressure to trigger GC.
        if previous do
          {_, _, terminal} = previous
          ExRatatui.safe_restore_terminal(terminal)
        end

        terminal = ExRatatui.init_test_terminal(width, height)
        Process.put(key, {width, height, terminal})
        terminal
    end
  end
end
