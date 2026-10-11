defmodule Alto.TUI.Catalog do
  @moduledoc "Delegates to the shared native-free Contrib catalog."
  defdelegate read(opts \\ []), to: Alto.Contrib.Catalog
  defdelegate invalid_data?(reason), to: Alto.Contrib.Catalog
  defdelegate replace_invalid(opts \\ []), to: Alto.Contrib.Catalog
  defdelegate register_project(root, opts \\ []), to: Alto.Contrib.Catalog
  defdelegate create_task(project, title, opts \\ []), to: Alto.Contrib.Catalog
  defdelegate update_task(id, attrs, opts \\ []), to: Alto.Contrib.Catalog
  defdelegate projects(opts \\ []), to: Alto.Contrib.Catalog
  defdelegate navigation(opts \\ []), to: Alto.Contrib.Catalog
  defdelegate close_project(id, opts \\ []), to: Alto.Contrib.Catalog
  defdelegate default_path(opts \\ []), to: Alto.Contrib.Catalog
end
