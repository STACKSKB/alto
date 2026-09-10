defmodule Alto.Runner.Serial.Result do
  @moduledoc "The inspectable result of one serial Alto run."

  @enforce_keys [
    :output,
    :loop_state,
    :messages,
    :events,
    :events_dropped,
    :verdict,
    :model_requests,
    :transcript_bytes,
    :session_id,
    :run_id
  ]
  defstruct [
    :output,
    :loop_state,
    :messages,
    :events,
    :events_dropped,
    :verdict,
    :model_requests,
    :transcript_bytes,
    :session_id,
    :run_id,
    checkpoint: nil,
    usage: %{},
    persistence: :not_requested
  ]

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
          checkpoint: map() | nil,
          usage: map(),
          persistence: :not_requested | :ok | {:degraded, [term()]}
        }
end
