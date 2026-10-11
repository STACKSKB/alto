defmodule Alto.TUI.Folders do
  @moduledoc "Delegates to the shared native-free Contrib folders."
  defdelegate create(path, base), to: Alto.Contrib.Folders
  defdelegate suggest(path, base), to: Alto.Contrib.Folders
end
