defmodule Alto.TUI.Transcript do
  @moduledoc "Shared cached conversation formatting; assistant Markdown, literal user/tool content."
  alias ExRatatui.{Text, Style}
  alias ExRatatui.Text.{Line, Span}

  def render(entries, width, assistant \\ "alto") do
    document(entries, width, assistant).text
  end

  def document(entries, width, assistant \\ "alto", opts \\ []) do
    cached(:documents, {entries, width, assistant, opts}, 4, fn ->
      groups = Enum.map(entries, &cached_rows(&1, width, assistant, opts))

      document = %{
        text: Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten()),
        groups: groups
      }

      {document, length(document.text.lines)}
    end)
  end

  @doc "Native row-count index; off-screen styled cells are never materialized."
  def index(entries, width, opts \\ []) do
    cached(:indexes, {entries, width, opts}, 4, fn ->
      # Worker-local caches disappear when indexing tasks exit. Reuse plans
      # from the previous budgeted index before dispatching any changed entries.
      previous =
        case Alto.TUI.Cache.latest({__MODULE__, :indexes}) do
          {{_, ^width, ^opts}, index} ->
            Map.new(index.parts, fn {entry, plan, _, _} -> {entry, plan} end)

          _ ->
            %{}
        end

      missing = entries |> Enum.reject(&Map.has_key?(previous, &1)) |> Enum.uniq()

      markdown =
        missing
        |> Enum.filter(
          &(&1[:kind] in [:assistant, :codex_assistant, :reasoning] and is_binary(&1[:text]))
        )
        |> Enum.map(& &1.text)
        |> Alto.TUI.Markdown.layouts(width)

      build = fn entry ->
        plan =
          cond do
            entry[:kind] in [:assistant, :codex_assistant, :reasoning] and
                is_binary(entry[:text]) ->
              {:markdown, Map.fetch!(markdown, entry.text)}

            to_string(entry[:kind]) in ["assistant", "codex_assistant", "reasoning"] and
                is_binary(entry[:text]) ->
              # Preserve the full-render path for non-atom roles, including styles.
              {:styled, cached_rows(entry, width, "alto", opts)}

            true ->
              {:literal, Alto.TUI.Viewport.rows(text(entry, opts), width)}
          end

        {entry, plan}
      end

      built =
        if length(missing) < 32 do
          Enum.map(missing, build)
        else
          missing
          |> Enum.chunk_every(16)
          |> Task.async_stream(&Enum.map(&1, build),
            max_concurrency: 4,
            ordered: true,
            timeout: 30_000
          )
          |> Enum.flat_map(fn {:ok, plans} -> plans end)
        end

      plans = Map.merge(previous, Map.new(built))

      {parts, rows} =
        Enum.map_reduce(entries, 0, fn entry, offset ->
          plan = Map.fetch!(plans, entry)

          count =
            case plan do
              {:markdown, layout} -> layout.rows + 1
              {:styled, lines} -> length(lines)
              {:literal, rows} -> tuple_size(rows)
            end

          {{entry, plan, offset, count}, offset + count + 1}
        end)

      # Literal rows stay as strings until a caller requests visible lines.
      # Charge entries rather than visual rows so long histories remain cached.
      {%{parts: parts, rows: max(rows - 1, 0)}, max(length(entries), 1)}
    end)
  end

  def plain_groups(index) do
    Enum.map(index.parts, fn {entry, plan, _, _} ->
      case plan do
        {:literal, rows} ->
          rows |> Tuple.to_list() |> Enum.map(&literal_line/1)

        {:styled, rows} ->
          rows

        {:markdown, layout} ->
          body = Alto.TUI.Markdown.plain_rows(layout)

          [
            assistant_label(entry, "alto")
            | Enum.map(body, &Line.new([Span.new(&1)]))
          ]
      end
    end)
  end

  def window(index, offset, height) do
    last = min(offset + height, index.rows)

    if last <= offset do
      []
    else
      rows =
        Enum.reduce(index.parts, %{}, fn {entry, plan, first, count}, acc ->
          start = max(offset, first)
          stop = min(last, first + count)

          if stop > start do
            lines =
              case plan do
                {:literal, rows} ->
                  for row <- (start - first)..(stop - first - 1),
                      do: rows |> elem(row) |> literal_line()

                {:styled, rows} ->
                  Enum.slice(rows, start - first, stop - start)

                {:markdown, layout} ->
                  body =
                    Alto.TUI.Markdown.window(
                      layout,
                      max(start - first - 1, 0),
                      stop - max(start, first + 1)
                    )

                  if start == first, do: [assistant_label(entry, "alto") | body], else: body
              end

            Enum.with_index(lines, start)
            |> Enum.reduce(acc, fn {row, n}, acc -> Map.put(acc, n, row) end)
          else
            acc
          end
        end)

      Enum.map(offset..(last - 1), &Map.get(rows, &1, Line.new([])))
    end
  end

  # Preserve absolute coordinates without allocating hidden placeholder rows.
  def viewport(entries, width, offset, height, opts \\ []) do
    index = index(entries, width, opts)
    offset = min(offset, max(index.rows - height, 0))
    lines = window(index, offset, height)

    %Alto.TUI.Window{lines: lines, offset: offset, rows: index.rows}
  end

  @doc "Render only enough final entries to fill the followed viewport."
  def tail(entries, width, height, assistant \\ "alto") do
    height = max(height, 1)

    {groups, _} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn entry, {groups, count} ->
        rows = tail_rows(entry, width, assistant, height)
        count = count + length(rows) + if(groups == [], do: 0, else: 1)
        result = {[rows | groups], count}
        if count >= height, do: {:halt, result}, else: {:cont, result}
      end)

    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten() |> Enum.take(-height))
  end

  defp tail_rows(entry, width, assistant, height) do
    if to_string(entry[:kind]) in ["assistant", "codex_assistant", "reasoning"] and
         is_binary(entry[:text]) do
      cached(:entries, {entry, width, assistant, {:tail, height}}, 512, fn ->
        rows =
          [
            assistant_label(entry, assistant)
            | Alto.TUI.Markdown.tail(entry.text, width, height).lines
          ]
          |> Enum.take(-height)

        {rows, length(rows)}
      end)
    else
      cached_rows(entry, width, assistant, [])
    end
  end

  defp assistant_label(entry, assistant) do
    label =
      case to_string(entry[:kind]) do
        "codex_assistant" -> "codex"
        "reasoning" -> "thinking"
        _ -> assistant
      end

    Line.new([Span.new(label <> " ›", style: %Style{fg: {:rgb, 150, 160, 175}})])
  end

  defp literal_line(row), do: Line.new([Span.new(row)])

  defp cached_rows(entry, width, assistant, opts) do
    cached(:entries, {entry, width, assistant, opts}, 512, fn ->
      rows = entry_rows(entry, width, assistant, opts)
      {rows, length(rows)}
    end)
  end

  defp cached(kind, id, limit, build) do
    Alto.TUI.Cache.fetch({__MODULE__, kind}, id, limit, fn ->
      {value, _rows} = build.()
      value
    end)
  end

  defp entry_rows(entry, width, assistant, opts) do
    kind = to_string(entry[:kind] || "message")

    if kind in ["assistant", "codex_assistant", "reasoning"] and is_binary(entry[:text]) do
      [assistant_label(entry, assistant) | Alto.TUI.Markdown.render(entry.text, width).lines]
    else
      Alto.TUI.Viewport.rows(text(entry, opts), width)
      |> Tuple.to_list()
      |> Enum.map(&Line.new([Span.new(&1)]))
    end
  end

  def text(entry, opts \\ []) do
    kind = to_string(entry[:kind] || "message")

    label =
      case kind do
        "user" -> "you › "
        "reasoning" -> "thinking › "
        "tool" -> "tool · "
        "error" -> "error ! "
        _ -> "· "
      end

    value = entry[:text]

    text =
      case kind do
        role when role in ["tool", "activity"] -> Alto.Contrib.Display.result(entry[:text])
        "error" -> Alto.Contrib.Display.error(entry[:text])
        role when role in ["user", "reasoning"] and is_binary(value) -> entry.text
        _ -> Alto.Contrib.Display.text(entry[:text])
      end

    detail =
      if entry[:detail] in [nil, "", %{}, []],
        do: "",
        else: "\n" <> preview(entry.detail, opts)

    text = if kind in ["tool", "activity"], do: preview(text, opts), else: text
    label <> text <> detail
  end

  defp preview(value, opts) do
    if opts[:expanded],
      do: Alto.Contrib.Display.result(value, limit: 20_000),
      else: preview(value)
  end

  defp preview(value) do
    text = Alto.Contrib.Display.result(value, limit: 1_200)
    lines = String.split(text, "\n")
    shown = Enum.take(lines, 6) |> Enum.join("\n")

    if length(lines) > 6 or byte_size(text) >= 1_200,
      do: shown <> "\n[… output truncated]",
      else: shown
  end
end
