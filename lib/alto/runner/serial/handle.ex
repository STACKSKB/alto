defmodule Alto.Runner.Serial.Handle do
  @moduledoc "A handle for awaiting or cancelling an asynchronous serial run."

  @enforce_keys [:task, :cancel_ref]
  defstruct [:task, :cancel_ref]

  @opaque t :: %__MODULE__{task: Task.t(), cancel_ref: reference()}
end
