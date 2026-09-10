defmodule Alto.Tool.Context do
  @moduledoc "Immutable execution context passed to a supervised tool task."

  @enforce_keys [:session_id, :cwd]
  defstruct [:session_id, :cwd, :metadata]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          metadata: map() | nil
        }
end
