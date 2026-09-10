defmodule Alto.Context.Transcript do
  @moduledoc "Pure provider-history validation and conversation-safe compaction boundaries."

  @doc "Validate call/reply correlation. In-progress histories may retain unanswered calls."
  def validate(messages, opts \\ [])

  def validate(messages, opts) when is_list(messages) do
    with {:ok, pending} <- Enum.reduce_while(messages, {:ok, %{}}, &consume/2) do
      if pending == %{} or Keyword.get(opts, :allow_pending, false),
        do: :ok,
        else: {:error, {:unanswered_tool_calls, Map.keys(pending)}}
    end
  end

  def validate(_, _), do: {:error, :invalid_messages}

  @doc "Keep at least the requested recent messages, moving the split back to a complete boundary."
  def split(messages, keep) do
    {system, rest} =
      case messages do
        [%{"role" => "system"} = system | rest] -> {[system], rest}
        rest -> {[], rest}
      end

    target = max(length(rest) - keep, 0)

    {boundary, _pending} =
      rest
      |> Enum.take(target)
      |> Enum.with_index(1)
      |> Enum.reduce({0, %{}}, fn {message, index}, {boundary, pending} ->
        case consume(message, {:ok, pending}) do
          {:cont, {:ok, next}} -> {if(next == %{}, do: index, else: boundary), next}
          {:halt, _error} -> {boundary, pending}
        end
      end)

    {middle, recent} = Enum.split(rest, boundary)
    {system, middle, recent}
  end

  def bytes(messages), do: Enum.reduce(messages, 0, &(byte_size(JSON.encode!(&1)) + &2))

  @doc "Close unanswered calls from an interrupted run without replaying their effects."
  def close_interrupted(messages) do
    with {:ok, pending} <- Enum.reduce_while(messages, {:ok, %{}}, &consume/2) do
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

  defp consume(%{"role" => "assistant", "tool_calls" => calls}, {:ok, pending})
       when is_list(calls) do
    if pending != %{} do
      {:halt, {:error, {:unanswered_tool_calls, Map.keys(pending)}}}
    else
      Enum.reduce_while(calls, {:cont, {:ok, %{}}}, fn
        %{"id" => id}, {:cont, {:ok, acc}} when is_binary(id) and id != "" ->
          {:cont, {:cont, {:ok, Map.update(acc, id, 1, &(&1 + 1))}}}

        _, _ ->
          {:halt, {:halt, {:error, :invalid_tool_call}}}
      end)
    end
  end

  defp consume(%{"role" => "tool", "tool_call_id" => id}, {:ok, pending}) do
    case pending do
      %{^id => 1} -> {:cont, {:ok, Map.delete(pending, id)}}
      %{^id => n} -> {:cont, {:ok, Map.put(pending, id, n - 1)}}
      _ -> {:halt, {:error, {:orphan_tool_reply, id}}}
    end
  end

  defp consume(%{"role" => role}, {:ok, pending}) when role in ["system", "user", "assistant"] do
    if pending == %{},
      do: {:cont, {:ok, pending}},
      else: {:halt, {:error, {:unanswered_tool_calls, Map.keys(pending)}}}
  end

  defp consume(_, _), do: {:halt, {:error, :invalid_message}}
end
