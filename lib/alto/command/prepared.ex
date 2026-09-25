defmodule Alto.Command.Prepared do
  @moduledoc "A command and execution profile frozen before an approval decision."

  @enforce_keys [:executor, :execution, :approval_details]
  defstruct [:executor, :execution, :approval_details]

  @type t :: %__MODULE__{
          executor: module(),
          execution: term(),
          approval_details: map()
        }
end
