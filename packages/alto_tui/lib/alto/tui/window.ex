defmodule Alto.TUI.Window do
  @moduledoc "Visible styled rows with their absolute position and complete history size."
  @enforce_keys [:lines, :offset, :rows]
  defstruct [:lines, :offset, :rows]
end
