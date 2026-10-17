defmodule Alto.Contrib.Resident.Tools.ApplyWorkerPatch do
  @moduledoc "Apply a descendant worker's captured patch through Alto's prepared approval contract."
  use Alto.Tool, name: :apply_worker_patch, execution_mode: :exclusive, approval: :required

  def schema(_opts \\ []) do
    Alto.Tool.object_schema(
      "Apply a reviewed worker patch to this team's source checkout. " <>
        "Use the workspace ID and revision from the worker result. Approval binds the " <>
        "exact patch and affected files; changed files require a new review. " <>
        "Inspect the patch with review_worker_patch before requesting application.",
      %{
        workspace_id: %{type: "string"},
        revision: %{type: "integer", minimum: 0}
      },
      ["workspace_id", "revision"]
    )
  end

  def prepare(arguments, context, opts \\ [])

  def prepare(%{"workspace_id" => id, "revision" => revision} = args, context, opts)
      when map_size(args) == 2 do
    with {:ok, manager, info} <-
           Alto.Contrib.Resident.Workspaces.for_descendant(context, id, opts),
         {:ok, prepared} <- Alto.Contrib.Workspaces.prepare_apply(manager, id, revision),
         {:ok, patch} <- Alto.Contrib.Workspaces.patch(manager, id) do
      details = %{
        workspace_id: id,
        revision: revision,
        source: info.workspace["source"],
        sha256: prepared["patch_sha256"],
        bytes: byte_size(patch),
        files: affected_files(prepared["integration"]),
        preview: Alto.Contrib.Resident.Workspaces.patch_preview(patch)
      }

      {:ok, prepared, details}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_patch_arguments}

  # Backend-specific file lists are optional display data. The manager-level
  # source, revision and digest remain the authority for approval/application.
  defp affected_files(%{"files" => files}) when is_list(files),
    do: for(%{"path" => path} <- files, is_binary(path), do: path)

  defp affected_files(_), do: []

  def run(prepared, context, opts \\ [])

  def run(%{"workspace_id" => id} = prepared, context, opts) do
    with {:ok, manager, _} <- Alto.Contrib.Resident.Workspaces.for_descendant(context, id, opts),
         {:ok, info} <- Alto.Contrib.Workspaces.apply(manager, prepared) do
      {:ok, %{workspace_id: info.id, revision: info.revision, status: info.status}}
    end
  end

  def run(_, _, _), do: {:error, :invalid_prepared_patch}
end
