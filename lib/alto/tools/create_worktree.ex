defmodule Alto.Tools.CreateWorktree do
  @moduledoc "Create a retained local worktree using a host-configured workspace manager."
  use Alto.Tool,
    name: :create_worktree,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments
  alias Alto.Workspaces

  @impl true
  def arguments(_opts) do
    {"Create a local Git worktree from a committed ref, leaving current files untouched. Returns its cwd and workspace ID; does not switch this agent's cwd. Detached by default; branch creates a new branch. Reuse name within this session to identify the same creation.",
     name: [type: Arguments.text(1, 128), required: true],
     ref: [type: :string],
     branch: [type: {:or, [:string, {:in, [nil]}]}]}
  end

  @impl true
  def prepare(%{"name" => name} = args, context, opts) do
    with true <-
           not String.contains?(name, ["\n", "\r", <<0>>]) or
             {:error, :invalid_worktree_arguments},
         %Workspaces{backend: Alto.Workspaces.GitWorktree} = manager <- opts[:manager],
         {:ok, snapshot} <- Workspaces.prepare(manager, context.cwd, snapshot_options(args)) do
      identity = %{root_run_id: context.session_id, path: ["worktree", name]}
      prepared = %{manager: manager, snapshot: snapshot, identity: identity}

      {:ok, prepared,
       Map.merge(snapshot.metadata, %{"name" => name, "workspace_root" => manager.root})}
    else
      {:error, _} = error -> error
      _ -> {:error, :worktree_manager_required}
    end
  end

  @impl true
  def run(%{manager: manager, snapshot: snapshot, identity: identity}, _context, _opts) do
    with {:ok, info} <- Workspaces.create(manager, snapshot, identity) do
      {:ok,
       %{
         "workspace_id" => info.id,
         "cwd" => info.workspace["cwd"],
         "base_commit" => snapshot.metadata["base_commit"],
         "branch" => snapshot.metadata["branch"],
         "revision" => info.revision,
         "status" => info.status
       }}
    end
  end

  defp snapshot_options(args) do
    Enum.flat_map([ref: "ref", branch: "branch"], fn {key, field} ->
      if Map.has_key?(args, field), do: [{key, args[field]}], else: []
    end)
  end
end
