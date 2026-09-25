defmodule Alto.Runner.Execution.History do
  @moduledoc """
  Optional conversation persistence and dispatch fencing for execution hosts.

  The scheduler chooses settled boundaries; this component performs bounded,
  cancellable writes and advances the revision used by the next dispatch.
  """
  alias Alto.Session
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Call

  def initialize({:ok, run}, opts) do
    if Keyword.get(opts, :checkpoint) || Keyword.get(opts, :continuation) do
      {:ok, run}
    else
      case persist(run) do
        {:ok, run} -> {:ok, run}
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  def initialize(error, _opts), do: error

  def persist(run, opts \\ [])

  def persist(%{session_history: :settled, session: nil} = run, _),
    do: {:error, :session_history_requires_session, run}

  def persist(%{session_history: :settled, resume_snapshot: true} = run, opts) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(run.messages_rev, [:deterministic]))

    if run.history_digest == digest and run.resolved_operations == [] do
      {:ok, run}
    else
      messages = Enum.reverse(run.messages_rev)

      options = [
        session_dir: run.session_dir,
        max_conversation_bytes: run.max_conversation_bytes,
        expected_revision: run.transcript_revision,
        resolved_operations: run.resolved_operations,
        context_observation:
          Alto.Context.Observation.dump(
            Map.get(run, :context_observation),
            messages
          ),
        allow_pending: Keyword.get(opts, :allow_pending, false)
      ]

      with {:ok, snapshot} <-
             storage_call(run, :session_history_failed, fn ->
               Session.Conversation.persist(run.session, messages, run.transcript_bytes, options)
             end) do
        {:ok,
         %{
           run
           | transcript_revision: snapshot.revision,
             resolved_operations: [],
             history_digest: digest
         }}
      end
    end
  end

  def persist(run, _), do: {:ok, run}

  def dispatch(run, []), do: {:ok, run}

  def dispatch(%{session_history: :settled, resume_snapshot: true} = run, operations) do
    with {:ok, run} <- settle_resolved(run) do
      mark_dispatched(run, operations)
    end
  end

  def dispatch(run, _), do: {:ok, run}

  defp settle_resolved(%{resolved_operations: [_ | _], pending_provider_calls: pending} = run)
       when map_size(pending) == 0,
       do: persist(run)

  defp settle_resolved(run), do: {:ok, run}

  defp mark_dispatched(run, operations) do
    with {:ok, _} <-
           storage_call(run, :session_dispatch_fence_failed, fn ->
             Session.mark_dispatched(run.session, operations,
               session_dir: run.session_dir,
               expected_revision: run.transcript_revision,
               run_id: run.tool_context.session_id
             )
           end),
         do: {:ok, run}
  end

  defp storage_call(run, failure, fun) do
    case Call.run(fun, Budget.remaining(run.budget), run.cancel_ref) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, {failure, reason}, run}
      {:error, reason} -> {:error, {failure, reason}, run}
      {:cancelled, reason} -> {:error, {:cancelled, reason}, run}
    end
  end

  def resolve(%{session_history: :settled} = run, id),
    do: %{run | resolved_operations: Enum.uniq([id | run.resolved_operations])}

  def resolve(run, _), do: run
end
