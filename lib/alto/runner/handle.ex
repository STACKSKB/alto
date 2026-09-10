defmodule Alto.Runner.Handle do
  @moduledoc "An opaque, runner-tagged execution handle."
  @enforce_keys [:runner, :state]
  defstruct [:runner, :state]
  @opaque t :: %__MODULE__{runner: module(), state: term()}
end
