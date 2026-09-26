defmodule Alto.Runner.Execution.Session do
  @moduledoc """
  Session persistence for an execution host.

  This module persists transcript revisions and completion records;
  the scheduler supplies only the run fields needed by those writes. Persistence
  remains best-effort and is reflected in the neutral `Alto.Runner.Result`.
  """

  alias Alto.Session, as: DurableSession
  alias Alto.Runner.Result

  require Logger

  @type outcome ::
          {:ok, Result.t()}
          | {:error, term(), Result.t()}

  @doc "Persist the terminal or suspended outcome using the required run fields."
  @spec persist_outcome(map(), outcome()) :: outcome()
  def persist_outcome(%{session: nil}, outcome) do
    # A run without a transcript can still request durable child journals.
    # Keep their persistence failures visible instead of erasing them here.
    result = elem(outcome, tuple_size(outcome) - 1)

    put_persistence(
      outcome,
      result,
      Result.persistence_status(Result.persistence_errors(result), :not_requested)
    )
  end

  def persist_outcome(state, outcome) do
    result = elem(outcome, tuple_size(outcome) - 1)
    {status, reason, save_transcript?} = completion(outcome)

    {result, transcript_errors} =
      if save_transcript?, do: persist_transcript(state, result), else: {result, []}

    errors =
      Result.persistence_errors(result) ++
        transcript_errors ++
        persist_completed(state, status, reason, result)

    put_persistence(outcome, result, Result.persistence_status(errors))
  end

  defp completion({:ok, _result}), do: {"ok", nil, true}
  defp completion({:error, :execution_suspended, _result}), do: {"suspended", nil, false}

  defp completion({:error, :approval_suspended, _result}), do: {"suspended", nil, false}

  defp completion({:error, reason, %{checkpoint: %{"kind" => kind}}})
       when kind in ["parent", "child"] do
    status =
      case reason do
        {:cancelled, _} -> "cancelled"
        {:children_pending, _} -> "suspended"
        _ -> "error"
      end

    {status, reason, false}
  end

  defp completion({:error, {:cancelled, cause}, _result}), do: {"cancelled", cause, true}
  defp completion({:error, reason, _result}), do: {"error", reason, true}

  defp persist_transcript(%{resume_snapshot: false}, result), do: {result, []}
  defp persist_transcript(_state, %{transcript_persisted: true} = result), do: {result, []}

  defp persist_transcript(%{checkpoint_resume: true}, %{loop_state: nil} = result),
    do: {result, []}

  defp persist_transcript(%{} = state, result) do
    case DurableSession.Conversation.persist(
           state.session,
           result.messages,
           result.transcript_bytes,
           session_dir: state.session_dir,
           expected_revision: result.transcript_revision || state.transcript_revision,
           resolved_operations: result.resolved_operations,
           context_observation: result.context_observation,
           allow_pending: true,
           max_conversation_bytes: state.max_conversation_bytes
         ) do
      {:ok, snapshot} ->
        {%{
           result
           | transcript_revision: snapshot.revision,
             resolved_operations: [],
             transcript_persisted: true
         }, []}

      {:error, reason} ->
        Logger.warning("alto: session transcript not persisted: #{inspect(reason, limit: 5)}")
        {result, [reason]}
    end
  end

  defp persist_completed(state, outcome, reason, result) do
    record =
      DurableSession.completed_record(%{
        run_id: state.tool_context.session_id,
        subagent: state.agent_depth > 0,
        session_owner: state.agent_depth == 0 or state.resume_snapshot,
        outcome: outcome,
        reason: reason,
        output: result.output,
        model_requests: result.model_requests
      })

    case DurableSession.append(state.session, record, session_dir: state.session_dir) do
      :ok ->
        []

      {:error, reason} ->
        Logger.warning("alto: session completion not persisted: #{inspect(reason, limit: 5)}")
        [reason]
    end
  end

  defp put_persistence(outcome, result, status),
    do: put_elem(outcome, tuple_size(outcome) - 1, %{result | persistence: status})
end
