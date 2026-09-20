defmodule Alto.Runner.Result do
  @moduledoc "The inspectable result of one Alto run."

  defstruct output: nil,
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
            usage: Alto.Usage.to_map(Alto.Usage.new()),
            persistence: :not_requested

  @type t :: %__MODULE__{
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
          agent_identity: %{root_run_id: binary(), path: [binary()]} | nil,
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
end
