defmodule Alto.Context.Reducers.Summary do
  @behaviour Alto.Context.Reducer
  alias Alto.Context.Reducer

  @impl true
  def compact(input, model, _opts) do
    prompt =
      "Summarize this agent work transcript so the run can continue without it. " <>
        "Preserve: the active task and any plan, key decisions taken, files read or modified, " <>
        "tool outcomes the next steps depend on, errors and how they were handled, and anything " <>
        "explicitly marked unresolved. Omit pleasantries and repetition. " <>
        "Reply with plain text under #{input.max_summary_bytes} bytes, no tool calls."

    request =
      Reducer.request(
        input,
        prompt <> "\n\nTranscript:\n" <> input.text,
        prompt <> " Use the preceding conversation."
      )

    case model.(request) do
      {:ok, %{message: message}} when is_binary(message) and message != "" ->
        {:ok, product(input, Alto.Text.prefix(message, input.max_summary_bytes))}

      {:error, _} = error ->
        error

      _ ->
        {:error, :compaction_summary_empty}
    end
  end

  def product(input, summary) do
    %{
      content:
        "[alto compaction: summarized #{length(input.middle)} messages; full history in session log]\n" <>
          summary,
      data: %{
        strategy: :summary,
        summarized_bytes: byte_size(input.text),
        summary_bytes: byte_size(summary),
        summary: summary
      }
    }
  end
end
