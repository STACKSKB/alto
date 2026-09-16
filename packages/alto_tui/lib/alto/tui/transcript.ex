defmodule Alto.TUI.Transcript do
  @moduledoc "Shared cached conversation formatting; assistant Markdown, literal user/tool content."
  alias ExRatatui.{Text, Style}
  alias ExRatatui.Text.{Line, Span}

  def render(entries, width, assistant \\ "alto") do
    key = {__MODULE__, :document}

    case Process.get(key) do
      {^entries, ^width, ^assistant, text} ->
        text

      _ ->
        text = render_entries(entries, width, assistant)
        Process.put(key, {entries, width, assistant, text})
        text
    end
  end

  defp render_entries(entries, width, assistant) do
    key = {__MODULE__, :entries}
    cache = Process.get(key, %{})

    {groups, next} =
      Enum.map_reduce(entries, %{}, fn entry, next ->
        id = {entry, width, assistant}
        rows = Map.get_lazy(cache, id, fn -> entry_rows(entry, width, assistant) end)
        {rows, Map.put(next, id, rows)}
      end)

    Process.put(key, next)
    Text.new(groups |> Enum.intersperse([Line.new([])]) |> List.flatten())
  end

  defp entry_rows(entry, width, assistant) do
    kind = to_string(entry[:kind] || "message")

    if kind in ["assistant", "codex_assistant"] and is_binary(entry[:text]) do
      label = if kind == "codex_assistant", do: "codex", else: assistant

      [
        Line.new([Span.new(label <> " ›", style: %Style{fg: {:rgb, 150, 160, 175}})])
        | Alto.TUI.Markdown.render(entry.text, width).lines
      ]
    else
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
        if entry[:detail] in [nil, ""],
          do: "",
          else: "\n" <> Alto.ToolDisplay.detail(entry.detail)

      Alto.TUI.Viewport.rows(label <> text <> detail, width)
      |> Tuple.to_list()
      |> Enum.map(&Line.new([Span.new(&1)]))
    end
  end
end
