defmodule Alto.Runner.Result do
  @moduledoc "The inspectable result of one Alto run."

  defstruct status: :error,
            reason: nil,
            output: nil,
            loop_state: nil,
            messages: [],
            events: [],
            events_dropped: 0,
            verdict: :rejected_before_dispatch,
            model_requests: 0,
            transcript_bytes: 0,
            session_id: nil,
            run_id: nil,
            agent_identity: nil,
            transcript_revision: nil,
            context_observation: nil,
            resolved_operations: [],
            transcript_persisted: false,
            workspace: nil,
            checkpoint: nil,
            usage: Alto.Usage.new(),
            persistence: :not_requested

  @type status :: :ok | :error | :cancelled | :suspended
  @type t :: %__MODULE__{
          status: status(),
          reason: term(),
          output: term(),
          loop_state: term(),
          messages: [map()],
          events: [Alto.Event.t()],
          events_dropped: non_neg_integer(),
          verdict: :completed | :rejected_before_dispatch | :failed_known | :unknown | :empty,
          model_requests: non_neg_integer(),
          transcript_bytes: non_neg_integer(),
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          agent_identity: Alto.AgentIdentity.t() | nil,
          transcript_revision: non_neg_integer() | :any | nil,
          context_observation: map() | nil,
          resolved_operations: [binary()],
          transcript_persisted: boolean(),
          workspace: map() | nil,
          checkpoint: map() | nil,
          usage: map(),
          persistence: :not_requested | :ok | {:degraded, [term()]}
        }

  @doc "An empty outcome for failures before execution starts."
  def empty(session_id \\ nil), do: %__MODULE__{session_id: session_id}

  @doc "Build a failed or suspended completion, preserving its execution evidence."
  def error(reason, result \\ empty()) do
    {status, reason} =
      case reason do
        {:cancelled, cause} -> {:cancelled, cause}
        reason when reason in [:approval_suspended, :execution_suspended] -> {:suspended, reason}
        {:children_pending, _} -> {:suspended, reason}
        _ -> {:error, reason}
      end

    %{result | status: status, reason: reason}
  end

  @doc "Persistence failures in occurrence order."
  def persistence_errors(%{persistence: {:degraded, errors}}), do: errors
  def persistence_errors(result) when is_map(result), do: []

  @doc "Persistence status after a requested write, or the supplied status when no errors occurred."
  def persistence_status(errors, success \\ :ok)
  def persistence_status([], success), do: success
  def persistence_status(errors, _success), do: {:degraded, errors}
end
