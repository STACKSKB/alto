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

  @type outcome :: Result.t()

  @doc "Append a lifecycle record, returning any persistence errors. Build only when logging is enabled."
  def append(run, warning, build)
  def append(%{session: nil}, _warning, _build), do: []

  def append(run, warning, build) do
    case DurableSession.append(run.session, build.(), session_dir: run.session_dir) do
      :ok ->
        []

      {:error, reason} ->
        if warning, do: Logger.warning("alto: session #{warning}: #{inspect(reason, limit: 5)}")
        [reason]
    end
  end

  @doc "Persist the terminal or suspended outcome using the required run fields."
  @spec persist_outcome(map(), outcome()) :: outcome()
  def persist_outcome(%{session: nil}, result) do
    %{
      result
      | persistence: Result.persistence_status(Result.persistence_errors(result), :not_requested)
    }
  end

  def persist_outcome(state, result) do
    bound_checkpoint? =
      not is_nil(result.checkpoint) and result.checkpoint["kind"] in ["parent", "child"]

    save_transcript? = result.status != :suspended and not bound_checkpoint?

    {result, transcript_errors} =
      if save_transcript?, do: persist_transcript(state, result), else: {result, []}

    errors =
      Result.persistence_errors(result) ++
        transcript_errors ++
        persist_completed(state, result)

    %{result | persistence: Result.persistence_status(errors)}
  end

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
           | transcript_revision: snapshot["revision"],
             resolved_operations: [],
             transcript_persisted: true
         }, []}

      {:error, reason} ->
        Logger.warning("alto: session transcript not persisted: #{inspect(reason, limit: 5)}")
        {result, [reason]}
    end
  end

  defp persist_completed(state, result) do
    append(state, "completion not persisted", fn ->
      DurableSession.completed_record(%{
        run_id: state.session_id,
        subagent: state.agent_depth > 0,
        session_owner: state.agent_depth == 0 or state.resume_snapshot,
        status: result.status,
        reason: result.reason,
        output: result.output,
        model_requests: result.model_requests
      })
    end)
  end
end
