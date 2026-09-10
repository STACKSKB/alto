defmodule Alto.Tool.Context do
  @moduledoc "Immutable execution context passed to a supervised tool task."

  @enforce_keys [:session_id, :cwd]
  defstruct [:session_id, :cwd, :metadata, :agent_identity]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          metadata: map() | nil,
          agent_identity: %{root_run_id: binary(), path: [binary()]} | nil
        }
end
