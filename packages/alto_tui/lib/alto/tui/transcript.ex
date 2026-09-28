defmodule Alto.TUI.Transcript do
  @moduledoc "Shared cached conversation formatting; assistant Markdown, literal user/tool content."
  alias ExRatatui.{Text, Style}
  alias ExRatatui.Text.{Line, Span}

  def render(entries, width, assistant \\ "alto") do
    document(entries, width, assistant).text
  end

  def document(entries, width, assistant \\ "alto", opts \\ []) do
    key = {__MODULE__, :document}

    case Process.get(key) do
      {^entries, ^width, ^assistant, ^opts, text} ->
        text

      _ ->
        text = render_entries(entries, width, assistant, opts)
        Process.put(key, {entries, width, assistant, opts, text})
        text
    end
  end

  defp render_entries(entries, width, assistant, opts) do
    key = {__MODULE__, :entries}
    cache = Process.get(key, %{})

    {groups, next} =
      Enum.map_reduce(entries, %{}, fn entry, next ->
        id = {entry, width, assistant, opts}
        rows = Map.get_lazy(cache, id, fn -> entry_rows(entry, width, assistant, opts) end)
        {rows, Map.put(next, id, rows)}
      end)

    Process.put(key, next)

    %{
      text: Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten()),
      groups: groups
    }
  end

  defp entry_rows(entry, width, assistant, opts) do
    kind = to_string(entry[:kind] || "message")

    if kind in ["assistant", "codex_assistant", "reasoning"] and is_binary(entry[:text]) do
      label =
        case kind do
          "codex_assistant" -> "codex"
          "reasoning" -> "thinking"
          _ -> assistant
        end

      [
        Line.new([Span.new(label <> " ›", style: %Style{fg: {:rgb, 150, 160, 175}})])
        | Alto.TUI.Markdown.render(entry.text, width).lines
      ]
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
        role when role in ["tool", "activity"] -> Alto.Display.result(entry[:text])
        "error" -> Alto.Display.error(entry[:text])
        role when role in ["user", "reasoning"] and is_binary(value) -> entry.text
        _ -> Alto.Display.text(entry[:text])
      end

    detail =
      if entry[:detail] in [nil, "", %{}, []],
        do: "",
        else: "\n" <> preview(entry.detail, opts)

    text = if kind in ["tool", "activity"], do: preview(text, opts), else: text
    label <> text <> detail
  end

  defp preview(value, opts) do
    if opts[:expanded], do: Alto.Display.result(value, limit: 20_000), else: preview(value)
  end

  defp preview(value) do
    text = Alto.Display.result(value, limit: 1_200)
    lines = String.split(text, "\n")
    shown = Enum.take(lines, 6) |> Enum.join("\n")

    if length(lines) > 6 or byte_size(text) >= 1_200,
      do: shown <> "\n[… output truncated]",
      else: shown
  end
end
