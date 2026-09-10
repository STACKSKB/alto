defmodule Alto.Workspaces.Snapshot do
  @moduledoc "Immutable source identity and provider-owned snapshot metadata."

  @enforce_keys [:source, :metadata]
  defstruct [:source, :metadata]

  @type t :: %__MODULE__{source: Path.t(), metadata: map()}
end
