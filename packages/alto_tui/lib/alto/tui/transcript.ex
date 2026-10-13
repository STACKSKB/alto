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

      %{
        text: Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten()),
        groups: groups
      }
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
        |> Enum.filter(&markdown?/1)
        |> Enum.map(& &1.text)
        |> Alto.TUI.Markdown.layouts(width)

      build = fn entry ->
        plan =
          if markdown?(entry),
            do: {:markdown, Map.fetch!(markdown, entry.text)},
            else: {:literal, Alto.TUI.Viewport.rows(text(entry, opts), width)}

        {entry, plan}
      end

      built = Alto.TUI.Cache.build_many(missing, build)

      plans = Map.merge(previous, Map.new(built))

      {parts, rows} =
        Enum.map_reduce(entries, 0, fn entry, offset ->
          plan = Map.fetch!(plans, entry)

          count =
            case plan do
              {:markdown, layout} -> layout.rows + 1
              {:literal, rows} -> tuple_size(rows)
            end

          {{entry, plan, offset, count}, offset + count + 1}
        end)

      # Literal rows stay as strings until a caller requests visible lines.
      %{parts: parts, rows: max(rows - 1, 0)}
    end)
  end

  def plain_groups(index) do
    Enum.map(index.parts, fn {entry, plan, _, _} ->
      case plan do
        {:literal, rows} ->
          rows |> Tuple.to_list() |> Enum.map(&literal_line/1)

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
    Alto.TUI.Window.slice(index, offset, height, fn entry, plan, start, count ->
      case plan do
        {:literal, rows} ->
          for row <- start..(start + count - 1), do: rows |> elem(row) |> literal_line()

        {:markdown, layout} ->
          body =
            Alto.TUI.Markdown.window(
              layout,
              max(start - 1, 0),
              count - if(start == 0, do: 1, else: 0)
            )

          if start == 0, do: [assistant_label(entry, "alto") | body], else: body
      end
    end)
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

    Alto.TUI.Window.tail(entries, height, fn entry ->
      rows = tail_rows(entry, width, assistant, height)
      {rows, length(rows)}
    end)
  end

  defp tail_rows(entry, width, assistant, height) do
    if markdown?(entry) do
      cached(:entries, {entry, width, assistant, {:tail, height}}, 512, fn ->
        [
          assistant_label(entry, assistant)
          | Alto.TUI.Markdown.tail(entry.text, width, height).lines
        ]
        |> Enum.take(-height)
      end)
    else
      cached_rows(entry, width, assistant, [])
    end
  end

  @doc false
  def markdown?(entry),
    do:
      to_string(entry[:kind]) in ["assistant", "codex_assistant", "reasoning"] and
        is_binary(entry[:text])

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
      entry_rows(entry, width, assistant, opts)
    end)
  end

  defp cached(kind, id, limit, build),
    do: Alto.TUI.Cache.fetch({__MODULE__, kind}, id, limit, build)

  defp entry_rows(entry, width, assistant, opts) do
    if markdown?(entry) do
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
