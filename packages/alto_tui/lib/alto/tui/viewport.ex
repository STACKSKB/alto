defmodule Alto.TUI.Viewport do
  @moduledoc "Cache native word wrapping in chunks and paint only visible paragraph rows."
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Alto.TUI.SelectionRegions

  def widgets(widgets) do
    Enum.map(widgets, fn
      {%Paragraph{text: %ExRatatui.Text{lines: lines} = text, wrap: false, scroll: {offset, 0}} =
           widget, rect} ->
        inner = SelectionRegions.content_rect(widget, rect)

        {%{
           widget
           | text: %{text | lines: Enum.slice(lines, offset, max(inner.height, 0))},
             scroll: {0, 0}
         }, rect}

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

  def bottom(text, width, height),
    do:
      max(
        tuple_size(rows(String.trim_trailing(text), max(width, 1))) - max(height, 1),
        0
      )

  def rows(text, width) do
    key = {__MODULE__, :documents}
    documents = Process.get(key, [])

    case Enum.find(documents, fn {old, w, _} -> old == text and w == width end) do
      {_, _, rows} ->
        rows

      nil ->
        chunks = text |> String.split("\n", trim: false) |> Enum.chunk_every(128)
        cache = Process.get({__MODULE__, :chunks}, %{})

        {groups, next} =
          Enum.map_reduce(chunks, %{}, fn lines, next ->
            chunk = Enum.join(lines, "\n")
            chunk_key = {width, chunk}

            rows =
              Map.get_lazy(cache, chunk_key, fn ->
                lines
                |> Enum.chunk_by(
                  &(byte_size(&1) <= width and not Regex.match?(~r/[^\x20-\x7E]/, &1))
                )
                |> Enum.flat_map(fn group ->
                  if Enum.all?(
                       group,
                       &(byte_size(&1) <= width and not Regex.match?(~r/[^\x20-\x7E]/, &1))
                     ),
                     do: Enum.map(group, &String.trim_leading(&1, " ")),
                     else: wrap(Enum.join(group, "\n"), width)
                end)
              end)

            {rows, Map.put(next, chunk_key, rows)}
          end)

        # Retain only this document's bounded chunk working set and a few views.
        retained = Map.merge(cache, next)

        Process.put(
          {__MODULE__, :chunks},
          if(map_size(retained) <= 512, do: retained, else: next)
        )

        rows = groups |> List.flatten() |> List.to_tuple()
        Process.put(key, Enum.take([{text, width, rows} | documents], 4))
        rows
    end
  end

  defp slice(rows, offset, height) do
    last = min(offset + height, tuple_size(rows)) - 1
    if offset <= last, do: Enum.map_join(offset..last, "\n", &elem(rows, &1)), else: ""
  end

  defp wrap(text, width) do
    marker =
      Enum.find_value(0xE000..0xF8FF, fn n ->
        char = <<n::utf8>>
        if not String.contains?(text, char), do: char
      end)

    height = min(256, length(String.split(text, "\n")) + div(2 * byte_size(text), width) + 3)
    key = {__MODULE__, :terminal}

    terminal =
      case Process.get(key) do
        {^width, ^height, terminal} ->
          terminal

        _ ->
          terminal = ExRatatui.init_test_terminal(width, height)
          Process.put(key, {width, height, terminal})
          terminal
      end

    wrap_page(terminal, text <> "\n" <> marker, marker, width, height, 0, [])
  end

  defp flatten_rows(pages, width) do
    pages
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.map(&Alto.TUI.Selection.buffer_row_text(&1, width))
  end

  defp wrap_page(terminal, text, marker, width, height, offset, pages) do
    :ok = ExRatatui.draw(terminal, [])

    :ok =
      ExRatatui.draw(terminal, [
        {%Paragraph{text: text, wrap: true, scroll: {offset, 0}},
         %Rect{width: width, height: height}}
      ])

    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")

    case Enum.find_index(lines, &(&1 == marker)) do
      nil when offset < 65_024 ->
        wrap_page(terminal, text, marker, width, height, offset + height, [lines | pages])

      nil ->
        Enum.reverse([lines | pages]) |> List.flatten()

      count ->
        flatten_rows([Enum.take(lines, count) | pages], width)
    end
  end
end
