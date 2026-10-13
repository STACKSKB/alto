defmodule Alto.TUI.Worktrees do
  @moduledoc "Create retained local worktrees beside the harness catalog."

  def create(source, arguments, catalog_opts \\ []) do
    catalog = Keyword.get(catalog_opts, :path, Alto.Contrib.Catalog.default_path(catalog_opts))
    root = Path.join(Path.dirname(Path.expand(catalog)), "worktrees")

    with {:ok, ledger} <-
           Alto.OperationLog.start_link(
             id: "worktrees",
             name: nil,
             dir: Path.join(root, "ledger")
           ) do
      try do
        manager =
          Alto.Contrib.Workspaces.new(
            root: Path.join(root, "checkouts"),
            ledger: ledger,
            backend_options: [layout: :worktree]
          )

        context = %{
          cwd: source,
          session_id: "harness-worktree-" <> Base.encode16(:crypto.hash(:sha256, source))
        }

        with {:ok, result} <-
               Alto.Tool.run(Alto.Contrib.Tools.CreateWorktree, arguments, context,
                 manager: manager
               ),
             {:ok, project} <-
               Alto.Contrib.Catalog.register_project(
                 result["cwd"],
                 Keyword.put(catalog_opts, :name, arguments["name"])
               ) do
          {:ok, Map.put(result, "project", project)}
        end
      after
        GenServer.stop(ledger)
      end
    end
  end
end
