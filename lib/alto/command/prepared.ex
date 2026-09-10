defmodule Alto.Command.Prepared do
  @moduledoc "A command and execution profile frozen before an approval decision."

  alias Alto.Command.Invocation

  @enforce_keys [:invocation, :executor, :execution, :approval_details]
  defstruct [:invocation, :executor, :execution, :approval_details]

  @type t :: %__MODULE__{
          invocation: Invocation.t(),
          executor: module(),
          execution: term(),
          approval_details: map()
        }
end
