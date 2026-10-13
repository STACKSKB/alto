defmodule Alto.Contrib.Resident.Workspaces do
  @moduledoc "Resident workspace resources and operator review, backed by Alto."
  alias Alto.OperationLog
  alias Alto.Contrib.Workspaces
  alias Alto.Contrib.Resident.Service

  def child(config, name) do
    Supervisor.child_spec(
      {OperationLog,
       name: ledger(name),
       id: "workspaces",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: config.workspaces[:max_retained],
       max_log_bytes: config.workspaces[:max_log_bytes],
       max_recovery_bytes: 40_000,
       max_record_bytes: 100_000},
      id: __MODULE__
    )
  end

  def ledger(name \\ Service), do: Service.component(name, :workspaces)

  @doc "Pass this manager to Team.loop/1 as :workspaces in trusted profile configuration."
  def manager(state_dir, name \\ Service) do
    Workspaces.new(root: Path.join(state_dir, "workspaces"), ledger: ledger(name))
  end

  def commands(config, name) do
    manager = manager(config.state_dir, name)

    Map.new(~w(list get patch discard), fn action ->
      {"workspaces." <> action, fn args -> execute(manager, action, args) end}
    end)
  end

  defp execute(manager, "list", args) when is_map(args) do
    cursor = Map.get(args, "cursor", 0)

    if is_integer(cursor) and cursor >= 0 do
      keys = Enum.map(OperationLog.request(manager.ledger, {:entries, :all}), & &1.operation_key)
      page = Enum.slice(keys, cursor, 10)

      resources =
        Enum.flat_map(page, fn id ->
          case Workspaces.get(manager, id) do
            {:ok, info} -> [info]
            _ -> []
          end
        end)

      next = cursor + length(page)
      {:ok, %{workspaces: resources, next_cursor: if(next < length(keys), do: next)}}
    else
      {:error, :invalid_workspace_cursor}
    end
  end

  defp execute(manager, "get", %{"id" => id}) do
    with {:ok, info} <- Workspaces.get(manager, id), do: {:ok, public_info(info)}
  end

  defp execute(manager, "patch", %{"id" => id} = args) do
    patch_chunk(manager, id, Map.get(args, "cursor", 0))
  end

  defp execute(manager, "discard", %{"id" => id, "revision" => revision, "note" => note}) do
    with {:ok, info} <- Workspaces.discard(manager, id, revision, note),
         do: {:ok, public_info(info)}
  end

  defp execute(_manager, _action, _args), do: {:error, :invalid_workspace_command}

  @doc false
  def patch_chunk(manager, id, cursor) do
    with true <- is_integer(cursor) and cursor >= 0,
         {:ok, info} <- Workspaces.get(manager, id),
         {:ok, patch} <- Workspaces.patch(manager, id),
         true <- cursor <= byte_size(patch) do
      count = min(24_000, byte_size(patch) - cursor)
      next = cursor + count

      {:ok,
       %{
         workspace_id: id,
         revision: info.revision,
         sha256: info.workspace["patch_sha256"],
         bytes: byte_size(patch),
         encoding: "base64",
         chunk: patch |> binary_part(cursor, count) |> Base.encode64(),
         next_cursor: if(next < byte_size(patch), do: next)
       }}
    else
      false -> {:error, :invalid_workspace_cursor}
      {:error, _} = error -> error
    end
  end

  @doc false
  def for_descendant(
        %{agent_identity: %{root_run_id: root, path: path}, cwd: cwd},
        id,
        opts
      )
      when is_binary(root) and is_list(path) and is_binary(cwd) do
    with %Workspaces{} = manager <- Keyword.get(opts, :manager),
         {:ok, info} <- Workspaces.get(manager, id),
         %{"root_run_id" => ^root, "path" => child} when is_list(child) <-
           info.workspace["owner"],
         true <- length(child) > length(path) and Enum.take(child, length(path)) == path,
         true <- info.workspace["source"] == Path.expand(cwd) do
      {:ok, manager, info}
    else
      {:error, _} = error -> error
      _ -> {:error, :workspace_scope_mismatch}
    end
  end

  def for_descendant(_, _, _), do: {:error, :workspace_scope_mismatch}

  @doc false
  def patch_preview(patch) do
    preview = binary_part(patch, 0, min(byte_size(patch), 4_096))
    encoding = if String.valid?(preview), do: "utf8", else: "base64"

    %{
      encoding: encoding,
      text: if(encoding == "utf8", do: preview, else: Base.encode64(preview)),
      truncated: byte_size(preview) < byte_size(patch)
    }
  end

  defp public_info(info),
    do: info |> Map.delete(:id) |> Map.put(:workspace_id, info.id)
end
