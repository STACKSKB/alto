defmodule Alto.Session.Recovery do
  @moduledoc "Recovery of older cancelled runs whose final transcript could not clear dispatch."
  alias Alto.Session
  alias Alto.Session.Conversation
  alias Alto.Context.Transcript

  def cancelled(id, opts) do
    with {:ok, snapshot} <- Conversation.fetch(id, :latest, opts),
         %{"run_id" => run_id, "tool_call_ids" => operations} when is_binary(run_id) <-
           snapshot["dispatch"],
         {:ok, records} <- Session.read(id, opts),
         %{"type" => "completed", "status" => "cancelled", "run_id" => ^run_id} <-
           latest_owner(records),
         {:ok, messages} <- Transcript.close_interrupted(snapshot["messages"]) do
      last_model =
        Enum.find(Enum.reverse(records), fn record ->
          record["run_id"] == run_id and record["event"] == "model_completed"
        end)

      last_tools =
        case last_model && Session.event_data(last_model) do
          {:ok, data} when is_map(data) -> data["tool_calls"]
          _ -> nil
        end

      evidence = %{
        type: "alto_cancelled_run_recovery",
        run_id: run_id,
        unknown_operation_ids: operations,
        last_requested_tools: last_tools,
        outcome: "unknown",
        instruction:
          "The previous run was cancelled and its final transcript could not be saved. Work after the last saved boundary may be missing from this conversation. Inspect the workspace and reconcile these operations before requesting them again. Do not assume they failed or repeat them automatically."
      }

      messages = messages ++ [%{"role" => "user", "content" => JSON.encode!(evidence)}]
      bytes = Transcript.bytes(messages)

      if bytes <= Keyword.get(opts, :max_transcript_bytes, 8_000_000) do
        Conversation.persist(
          id,
          messages,
          bytes,
          Keyword.merge(
            Keyword.take(opts, [
              :session_dir,
              :max_conversation_bytes,
              :conversation_retained_turns
            ]),
            expected_revision: snapshot["revision"],
            resolved_operations: operations,
            conversation_turn_id: snapshot["turn_id"]
          )
        )
      else
        {:error, :recovery_transcript_too_large}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :cancelled_run_recovery_unavailable}
    end
  end

  defp latest_owner(records) do
    records
    |> Enum.reverse()
    |> Enum.find(fn record ->
      record["type"] in ["started", "completed"] and
        Map.get(record, "session_owner", not Map.get(record, "subagent", false))
    end)
  end
end
