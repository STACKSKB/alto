defmodule Alto.TUI.Activity do
  @moduledoc "A compact activity indicator on the conversation border, outside selectable text."
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Style

  def widgets(nil, _started, _tick, _rect), do: []
  def widgets(_label, _started, _tick, nil), do: []

  def widgets(label, started, tick, rect) do
    seconds =
      if is_integer(started),
        do: max(div(System.system_time(:millisecond) - started, 1000), 0),
        else: 0

    spinner = Enum.at(["◐", "◓", "◑", "◒"], rem(tick, 4))
    text = " #{spinner} #{label} · #{seconds}s "

    [
      {%Paragraph{text: text, style: %Style{fg: :light_blue}},
       %Rect{x: rect.x + 2, y: rect.y + rect.height - 1, width: max(rect.width - 4, 1), height: 1}}
    ]
  end

  def phase(event, fallback \\ "working") do
    case to_string(event || "") do
      event
      when event in [
             "context_compacting",
             "context_compaction_progress"
           ] ->
        "compacting context"

      "context_compacted" ->
        "context ready"

      "model_started" ->
        "waiting for model"

      "model_reasoning_delta" ->
        "thinking"

      "model_delta" ->
        "receiving response"

      "model_retry" ->
        "retrying provider connection"

      "model_completed" ->
        "processing response"

      "tool_started" ->
        "running tool"

      "tool_completed" ->
        "processing tool result"

      "approval_requested" ->
        "waiting for approval"

      "approval_resolved" ->
        "processing approval"

      _ ->
        fallback
    end
  end
end
