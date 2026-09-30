defmodule Alto.Contrib.Workspaces.GitWorktree do
  @moduledoc """
  Local linked Git worktrees sharing the source repository's objects and refs.

  Snapshots capture a committed ref (HEAD by default), leaving dirty source
  files untouched. Checkouts are detached unless `:branch` names a new branch.
  Like the clone backend, this provides separate working files, not a sandbox.
  Explicit discard removes Git's registration and working files, retaining any
  named branch. The source repository must remain available for the lifecycle.
  """
  @behaviour Alto.Contrib.Workspaces.Backend
  alias Alto.Contrib.Workspaces.Git

  @impl true
  def snapshot(source, opts \\ []), do: Git.snapshot(source, linked(opts))
  @impl true
  def checkout(snapshot, path, opts \\ []), do: Git.checkout(snapshot, path, linked(opts))
  @impl true
  def diff(snapshot, path, opts \\ []), do: Git.diff(snapshot, path, linked(opts))
  @impl true
  def discard(snapshot, path, opts \\ []), do: Git.discard(snapshot, path, linked(opts))
  @impl true
  def prepare_apply(source, path, sha, opts \\ []),
    do: Git.prepare_apply(source, path, sha, linked(opts))

  @impl true
  def verify_apply(source, integration, path, opts \\ []),
    do: Git.verify_apply(source, integration, path, linked(opts))

  @impl true
  def apply(source, integration, path, opts \\ []),
    do: Git.apply(source, integration, path, linked(opts))

  defp linked(opts), do: Keyword.put(opts, :layout, :worktree)
end
