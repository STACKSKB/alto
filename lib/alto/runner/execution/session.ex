defmodule Alto.Runner.Execution.Session do
  @moduledoc """
  Session persistence for an execution host.

  This module owns the append-only event, transcript and completion sidecars;
  the scheduler supplies only the run fields needed by those writes. Persistence
  remains best-effort and is reflected in the neutral `Alto.Runner.Result`.
  """

  alias Alto.Session, as: DurableSession
  alias Alto.Runner.Result

  require Logger

  @enforce_keys [
    :session,
    :session_id,
    :session_dir,
    :resume_snapshot,
    :checkpoint_resume,
    :transcript_revision,
    :agent_depth
  ]
  defstruct [
    :session,
    :session_id,
    :session_dir,
    :resume_snapshot,
    :checkpoint_resume,
    :transcript_revision,
    :agent_depth
  ]

  @type t :: %__MODULE__{
          session: DurableSession.session_id() | nil,
          session_id: binary(),
          session_dir: Path.t() | nil,
          resume_snapshot: boolean(),
          checkpoint_resume: boolean(),
          transcript_revision: non_neg_integer(),
          agent_depth: non_neg_integer()
        }

  @type outcome ::
          {:ok, Result.t()}
          | {:error, :approval_suspended, Result.t()}
          | {:error, term(), Result.t()}

  @doc "Project the persistence fields from a scheduler run state."
  @spec from_run(map()) :: t()
  def from_run(run) do
    %__MODULE__{
      session: run.session,
      session_id: run.tool_context.session_id,
      session_dir: run.session_dir,
      resume_snapshot: run.resume_snapshot,
      checkpoint_resume: Map.get(run, :checkpoint_resume, false),
      transcript_revision: run.transcript_revision,
      agent_depth: run.agent_depth
    }
  end

  @doc "Persist one durable event; failures are returned for host accounting."
  @spec persist_event(t(), term()) :: :ok | {:error, term()}
  def persist_event(%__MODULE__{session: nil}, _event), do: :ok

  def persist_event(%__MODULE__{} = state, event) do
    DurableSession.append(
      state.session,
      DurableSession.event_record(state.session_id, event),
      session_dir_opt(state)
    )
  end

  @doc "Persist the terminal or suspended outcome and attach degradation status."
  @spec persist_outcome(t(), outcome()) :: outcome()
  def persist_outcome(state, outcome), do: persist_session_outcome(state, outcome)

  @doc "Persist the terminal or suspended outcome and attach degradation status."
  @spec persist_session_outcome(t(), outcome()) :: outcome()
  def persist_session_outcome(%__MODULE__{session: nil}, outcome) do
    # A run without a transcript can still request durable child journals.
    # Keep their persistence failures visible instead of erasing them here.
    result = elem(outcome, tuple_size(outcome) - 1)

    status =
      case existing_persistence_errors(result) do
        [] -> :not_requested
        errors -> persistence_status(errors)
      end

    put_persistence(outcome, status)
  end

  def persist_session_outcome(%__MODULE__{} = state, {:ok, result}) do
    errors =
      existing_persistence_errors(result) ++
        persistence_errors([
          persist_transcript(state, result),
          persist_completed(state, "ok", nil, result)
        ])

    put_persistence({:ok, result}, persistence_status(errors))
  end

  def persist_session_outcome(%__MODULE__{} = state, {:error, :approval_suspended, result}) do
    # A paused run has no completed transcript. Its exact continuation is
    # persisted by the host ledger before acknowledging its claim.
    errors =
      existing_persistence_errors(result) ++
        persistence_errors([persist_completed(state, "suspended", nil, result)])

    put_persistence({:error, :approval_suspended, result}, persistence_status(errors))
  end

  def persist_session_outcome(%__MODULE__{} = state, {:error, reason, result}) do
    completion =
      case reason do
        {:cancelled, cause} -> persist_completed(state, "cancelled", cause, result)
        _other -> persist_completed(state, "error", reason, result)
      end

    errors =
      existing_persistence_errors(result) ++
        persistence_errors([persist_transcript(state, result), completion])

    put_persistence({:error, reason, result}, persistence_status(errors))
  end

  defp persist_transcript(%__MODULE__{resume_snapshot: false}, _result), do: :ok
  defp persist_transcript(%__MODULE__{checkpoint_resume: true}, %{loop_state: nil}), do: :ok

  defp persist_transcript(%__MODULE__{} = state, result) do
    case DurableSession.write_transcript(
           state.session,
           result.messages,
           result.transcript_bytes,
           Keyword.put(
             session_dir_opt(state),
             :expected_revision,
             state.transcript_revision
           )
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto: session transcript not persisted: #{inspect(reason, limit: 5)}")
        {:error, reason}
    end
  end

  defp persist_completed(state, outcome, reason, result) do
    record =
      DurableSession.completed_record(%{
        run_id: state.session_id,
        subagent: state.agent_depth > 0,
        session_owner: state.agent_depth == 0 or state.resume_snapshot,
        outcome: outcome,
        reason: reason,
        output: result.output,
        model_requests: result.model_requests
      })

    case DurableSession.append(state.session, record, session_dir_opt(state)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto: session completion not persisted: #{inspect(reason, limit: 5)}")
        {:error, reason}
    end
  end

  defp session_dir_opt(state), do: [session_dir: state.session_dir]

  defp existing_persistence_errors(%{persistence: {:degraded, errors}}), do: errors
  defp existing_persistence_errors(_result), do: []

  defp persistence_errors(results) do
    Enum.flat_map(results, fn
      :ok -> []
      {:error, reason} -> [reason]
    end)
  end

  defp persistence_status([]), do: :ok
  defp persistence_status(errors), do: {:degraded, errors}

  defp put_persistence({:ok, result}, status), do: {:ok, %{result | persistence: status}}

  defp put_persistence({:error, reason, result}, status),
    do: {:error, reason, %{result | persistence: status}}
end
