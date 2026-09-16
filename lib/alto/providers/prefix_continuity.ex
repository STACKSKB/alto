defmodule Alto.Providers.PrefixContinuity do
  @moduledoc """
  Content-free local request continuity, compared with the last successful request.

  Hashes describe Alto's message/tool JSON serialization, not provider-normalized
  HTTP bodies or tokenizer prefixes. No comparison is available at run start
  (including resume); this does not imply an upstream cold cache.
  """

  def report(%{messages: messages, tools: tools} = request) do
    messages_json = JSON.encode!(messages)
    tools_json = JSON.encode!(tools)

    report = %{
      scope: :messages_and_tools,
      comparison: :unavailable,
      messages_count: length(messages),
      messages_bytes: byte_size(messages_json),
      messages_sha256: hash(messages_json),
      tools_bytes: byte_size(tools_json),
      tools_sha256: hash(tools_json)
    }

    case request[:context_observation] do
      %{messages: previous, tools: previous_tools} when is_list(previous) ->
        previous_json = JSON.encode!(previous)
        prefix_json = messages |> Enum.take(length(previous)) |> JSON.encode!()
        tools_unchanged = tools_json == JSON.encode!(previous_tools)
        preserved = prefix_json == previous_json and tools_unchanged

        Map.merge(report, %{
          comparison: if(preserved, do: :preserved, else: :changed),
          previous_messages_count: length(previous),
          previous_messages_bytes: byte_size(previous_json),
          previous_messages_sha256: hash(previous_json),
          compared_prefix_sha256: hash(prefix_json),
          tools_unchanged: tools_unchanged
        })

      _ ->
        report
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
