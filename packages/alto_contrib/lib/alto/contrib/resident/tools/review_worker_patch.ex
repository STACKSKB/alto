defmodule Alto.Contrib.Resident.Tools.ReviewWorkerPatch do
  @moduledoc "Bounded, execution-scoped inspection of descendant worker patches."
  use Alto.Tool, name: :review_worker_patch, execution_mode: :parallel, approval: :never

  def schema(_opts \\ []) do
    Alto.Tool.object_schema(
      "Read a captured descendant worker patch before integrating it. Responses contain " <>
        "base64 chunks, the full SHA-256 and a next byte cursor. Read all chunks for full review.",
      %{
        workspace_id: %{type: "string"},
        cursor: %{type: "integer", minimum: 0}
      },
      ["workspace_id"]
    )
  end

  def run(args, context, opts \\ [])

  def run(%{"workspace_id" => id} = args, context, opts) do
    with true <- Map.keys(args) -- ~w(workspace_id cursor) == [],
         {:ok, manager, _} <- Alto.Contrib.Resident.Workspaces.for_descendant(context, id, opts) do
      Alto.Contrib.Resident.Workspaces.patch_chunk(manager, id, Map.get(args, "cursor", 0))
    else
      false -> {:error, :invalid_patch_arguments}
      error -> error
    end
  end

  def run(_, _, _), do: {:error, :invalid_patch_arguments}
end
