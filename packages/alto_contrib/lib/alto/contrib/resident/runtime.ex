defmodule Alto.Contrib.Resident.Runtime do
  @moduledoc "Server-side adapter for resident execution and its transport."

  @callback children(Alto.Contrib.Resident.Config.t(), term()) :: [Supervisor.child_spec()]
end
