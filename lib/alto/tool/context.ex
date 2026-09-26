defmodule Alto.Tool.Context do
  @moduledoc "Immutable execution context passed to a supervised tool task."

  @enforce_keys [:session_id, :cwd]
  defstruct [
    :session_id,
    :cwd,
    :metadata,
    :agent_identity,
    :messaging,
    :input,
    :input_reader,
    :messaging_tools,
    :budget
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          metadata: map() | nil,
          agent_identity: Alto.AgentIdentity.t() | nil,
          messaging: Alto.Messaging.Sender.t() | nil,
          input: term(),
          input_reader: term(),
          messaging_tools: list() | nil,
          budget: term()
        }
end
