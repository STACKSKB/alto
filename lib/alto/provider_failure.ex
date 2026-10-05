defmodule Alto.Provider.Failure do
  @moduledoc """
  A failed provider attempt with bounded accounting evidence.

  `reason` is the original adapter error. `usage: nil` means unavailable, rather
  than zero consumption. Metadata is reported by the provider, never inferred
  from the requested model. Diagnostics contain counters, not response text.
  """
  defstruct [:reason, :usage, metadata: %{}, diagnostics: %{}]

  @type t :: %__MODULE__{reason: term(), usage: map() | nil, metadata: map(), diagnostics: map()}

  def wrap(reason, evidence) do
    usage = evidence[:usage]
    metadata = Map.get(evidence, :metadata, %{})
    diagnostics = Map.get(evidence, :diagnostics, %{})

    if is_map(usage) or metadata != %{} or diagnostics != %{},
      do: %__MODULE__{reason: reason, usage: usage, metadata: metadata, diagnostics: diagnostics},
      else: reason
  end

  def reason(%__MODULE__{reason: reason}), do: reason
  def reason(reason), do: reason
end
