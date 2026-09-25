defmodule Alto.Context.Transcript do
  @moduledoc "Pure provider-history validation and conversation-safe compaction boundaries."

  @doc "Validate call/reply correlation. In-progress histories may retain unanswered calls."
  def validate(messages, opts \\ []) do
    with {:ok, pending} <- pending_calls(messages) do
      if pending == %{} or Keyword.get(opts, :allow_pending, false),
        do: :ok,
        else: {:error, {:unanswered_tool_calls, Map.keys(pending)}}
    end
  end

  @doc "Validate history and return counts of unanswered calls in its final batch."
  def pending_calls(messages) when is_list(messages),
    do: Alto.Result.reduce(messages, %{}, &consume/2)

  def pending_calls(_), do: {:error, :invalid_messages}

  @doc "Keep at least the requested recent messages, moving the split back to a complete boundary."
  def split(messages, keep, keep_initial \\ 0) do
    {system, rest} =
      case messages do
        [%{"role" => "system"} = system | rest] -> {[system], rest}
        rest -> {[], rest}
      end

    boundaries = complete_boundaries(rest)
    initial_end = Enum.find(Enum.reverse(boundaries), &(&1 >= keep_initial)) || length(rest)
    target = max(length(rest) - keep, initial_end)
    middle_end = max(initial_end, Enum.find(boundaries, &(&1 <= target)))
    {initial, rest} = Enum.split(rest, initial_end)
    {middle, recent} = Enum.split(rest, middle_end - initial_end)
    {system ++ initial, middle, recent}
  end

  # Newest first, including the empty prefix. A call group contributes a
  # boundary only once every reply has arrived.
  defp complete_boundaries(messages) do
    {boundaries, _pending} =
      messages
      |> Enum.with_index(1)
      |> Enum.reduce_while({[0], %{}}, fn {message, index}, {boundaries, pending} = acc ->
        case consume(message, pending) do
          {:ok, next} ->
            {:cont, {if(next == %{}, do: [index | boundaries], else: boundaries), next}}

          {:error, _} ->
            {:halt, acc}
        end
      end)

    boundaries
  end

  def bytes(messages), do: Enum.reduce(messages, 0, &(byte_size(JSON.encode!(&1)) + &2))

  @doc "Close unanswered calls from an interrupted run without replaying their effects."
  def close_interrupted(messages) do
    with {:ok, pending} <- pending_calls(messages) do
      replies =
        for {id, count} <- Enum.sort(pending), _ <- List.duplicate(nil, count) do
          %{
            "role" => "tool",
            "tool_call_id" => id,
            "content" =>
              JSON.encode!(%{
                outcome: "unknown",
                error:
                  "Previous run ended before this call settled. Reconcile its outcome before requesting it again."
              })
          }
        end

      {:ok, messages ++ replies}
    end
  end

  defp consume(%{"role" => "assistant", "tool_calls" => calls}, pending)
       when is_list(calls) do
    if pending != %{} do
      {:error, {:unanswered_tool_calls, Map.keys(pending)}}
    else
      Alto.Result.reduce(calls, %{}, fn
        %{"id" => id}, acc when is_binary(id) and id != "" ->
          {:ok, Map.update(acc, id, 1, &(&1 + 1))}

        _, _ ->
          {:error, :invalid_tool_call}
      end)
    end
  end

  defp consume(%{"role" => "tool", "tool_call_id" => id}, pending) do
    case pending do
      %{^id => 1} -> {:ok, Map.delete(pending, id)}
      %{^id => n} -> {:ok, Map.put(pending, id, n - 1)}
      _ -> {:error, {:orphan_tool_reply, id}}
    end
  end

  defp consume(%{"role" => role}, pending) when role in ["system", "user", "assistant"] do
    if pending == %{},
      do: {:ok, pending},
      else: {:error, {:unanswered_tool_calls, Map.keys(pending)}}
  end

  defp consume(_, _), do: {:error, :invalid_message}
end
