defmodule Alto.Workspaces do
  @moduledoc """
  Durable, revision-fenced workspace resources composed from `Alto.OperationLog`.

  A workspace is retained as a nonterminal ledger checkpoint until explicitly
  discarded. Creation, use and patch capture record dispatch before mutation.
  Interrupted operations are never silently repeated. The caller owns worker
  assignment and integration policy; this module starts no worker or scheduler.
  """
  alias Alto.{DurableLog, OperationLog, Storage}
  alias Alto.Workspaces.Snapshot

  @enforce_keys [:root, :ledger, :backend, :backend_options]
  defstruct [:root, :ledger, :backend, :backend_options]

  @type t :: %__MODULE__{
          root: binary(),
          ledger: GenServer.server(),
          backend: module(),
          backend_options: keyword()
        }

  def new(opts) do
    opts = Keyword.validate!(opts, [:root, :ledger, :backend, :backend_options])
    backend = Keyword.get(opts, :backend, Alto.Workspaces.Git)
    backend_options = Keyword.get(opts, :backend_options, [])

    unless is_atom(backend) and Code.ensure_loaded?(backend) and
             Enum.all?([snapshot: 2, checkout: 3, diff: 3], fn {f, a} ->
               function_exported?(backend, f, a)
             end) and Keyword.keyword?(backend_options),
           do: raise(ArgumentError, "invalid workspace backend")

    %__MODULE__{
      root: opts |> Keyword.fetch!(:root) |> Path.expand(),
      ledger: Keyword.fetch!(opts, :ledger),
      backend: backend,
      backend_options: backend_options
    }
  end

  @doc "Capture one immutable source for every workspace in a delegation batch."
  @spec prepare(t(), Path.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def prepare(%__MODULE__{} = manager, source) when is_binary(source) do
    source = Path.expand(source)

    with :ok <- separate_root(manager.root, source),
         {:ok, metadata} <- manager.backend.snapshot(source, manager.backend_options),
         :ok <- json_map(metadata) do
      {:ok, %Snapshot{source: source, metadata: metadata}}
    else
      {:error, _} = error -> error
    end
  end

  @doc "Create once for an execution-tree identity. Retain incomplete attempts for review."
  def create(%__MODULE__{} = manager, snapshot, identity) do
    with {:ok, %Snapshot{source: source, metadata: metadata}} <- normalize_snapshot(snapshot),
         :ok <- valid_identity(identity),
         :ok <- separate_root(manager.root, source) do
      id = "ws-" <> hash(:erlang.term_to_binary(identity))

      workspace = %{
        "id" => id,
        "owner" => Alto.Protocol.encode_term(identity),
        "source" => source,
        "snapshot" => metadata,
        "cwd" => Path.join([manager.root, id, "checkout"]),
        "backend" => Atom.to_string(manager.backend),
        "backend_fingerprint" => fingerprint(manager)
      }

      locked(manager, id, fn ->
        with :ok <- OperationLog.record_intent(manager.ledger, id, "workspace", nil, workspace),
             {:ok, info} <- get(manager, id),
             true <- Map.take(info.workspace, Map.keys(workspace)) == workspace do
          case info.status do
            "intended" -> create_workspace(manager, workspace)
            status when status in ["ready", "worked", "frozen", "applied"] -> {:ok, info}
            _ -> {:error, {:workspace_requires_review, id}}
          end
        else
          false -> {:error, :workspace_identity_conflict}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Read one consistent ledger status/revision without changing resource state."
  def get(%__MODULE__{} = manager, id) do
    with :ok <- valid_id(id),
         {:ok, entry} <- OperationLog.recovery(manager.ledger, id),
         true <- entry.tool == "workspace" and is_map(entry.recovery) do
      {status, workspace} = view(entry)
      {:ok, %{id: id, revision: entry.revision, status: status, workspace: workspace}}
    else
      false -> {:error, :invalid_workspace_record}
      {:error, _} = error -> error
    end
  end

  @doc "Hold the workspace lock throughout worker use; a crashed use remains dispatched."
  def use(%__MODULE__{} = manager, id, revision, fun) when is_function(fun, 1),
    do: use_at(manager, id, revision, fun, "ready")

  @doc "Continue a suspended worker at the exact retained workspace revision."
  def resume(%__MODULE__{} = manager, id, revision, fun) when is_function(fun, 1),
    do: use_at(manager, id, revision, fun, "worked")

  defp use_at(manager, id, revision, fun, expected_status) do
    locked(manager, id, fn ->
      with {:ok, info} <- expect(manager, id, revision),
           true <- info.status == expected_status,
           {:ok, attempt} <- activate(manager, info, "use") do
        result = fun.(info.workspace)

        recorded =
          try do
            checkpoint(manager, id, attempt, "worked", info.workspace)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case recorded do
          {:ok, updated} -> {:ok, result, updated}
          {:error, reason} -> {:error, {:workspace_checkpoint_failed, reason}, result}
        end
      else
        false -> {:error, :workspace_not_ready}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Freeze one bounded patch after worker use. The patch is outside the worker cwd."
  def freeze(%__MODULE__{} = manager, id, revision) do
    locked(manager, id, fn ->
      with {:ok, info} <- expect(manager, id, revision),
           true <- info.status in ["ready", "worked"],
           {:ok, attempt} <- activate(manager, info, "freeze"),
           {:ok, patch} <-
             manager.backend.diff(
               info.workspace["snapshot"],
               info.workspace["cwd"],
               manager.backend_options
             ),
           true <- is_binary(patch) and byte_size(patch) <= 1_000_000,
           path <- Path.join([manager.root, id, "patch.diff"]),
           :ok <- safe_path(path),
           :ok <- Storage.ensure_private_file(path),
           :ok <- DurableLog.replace(path, patch) do
        workspace =
          Map.merge(info.workspace, %{
            "patch_path" => path,
            "patch_sha256" => hash(patch),
            "patch_bytes" => byte_size(patch)
          })

        checkpoint(manager, id, attempt, "frozen", workspace)
      else
        false -> {:error, :workspace_not_freezable}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Read a retained captured patch whose bounded bytes still match its recorded hash."
  def patch(%__MODULE__{} = manager, id) do
    with {:ok, %{status: status, workspace: workspace}}
         when status in ["frozen", "applied", "in_progress", "pending_action"] <-
           get(manager, id),
         true <- workspace["patch_path"] == Path.join([manager.root, id, "patch.diff"]),
         :ok <- safe_path(workspace["patch_path"]),
         {:ok, patch} <- read_bounded(workspace["patch_path"], 1_000_000),
         true <- hash(patch) == workspace["patch_sha256"] do
      {:ok, patch}
    else
      false -> {:error, :workspace_patch_changed}
      {:ok, _} -> {:error, :workspace_not_frozen}
      {:error, _} = error -> error
    end
  end

  @doc """
  Prepare read-only approval data for applying a frozen patch through its backend.

  The returned portable manifest binds the resource revision, immutable patch,
  and backend integration data. Store it unchanged through approval; `apply/2`
  verifies it again before dispatch. No target or ledger writes occur.
  """
  def prepare_apply(%__MODULE__{} = manager, id, revision) do
    with {:ok, info} <- applicable(manager, id, revision),
         :ok <- integration_supported(manager),
         {:ok, _patch} <- patch(manager, id),
         {:ok, integration} <-
           backend_prepare_apply(
             manager,
             info.workspace["source"],
             info.workspace["patch_path"],
             info.workspace["patch_sha256"]
           ),
         :ok <- json_map(integration),
         {:ok, ^info} <- applicable(manager, id, revision) do
      {:ok,
       %{
         "workspace_id" => id,
         "revision" => revision,
         "patch_sha256" => info.workspace["patch_sha256"],
         "integration" => integration
       }}
    else
      {:ok, _} -> {:error, :stale_workspace}
      error -> error
    end
  end

  @doc """
  Apply exactly a prepared patch, fencing the resource and serializing this
  manager's integrations into the same target. The Git staging area is unchanged.

  Preconditions fail with `{:error, reason}` before target mutation. Failures
  after dispatch return `{:unknown, reason}` and retain the interrupted resource
  for review; never retry them automatically. Success retains an `applied`
  checkpoint and its patch until explicit discard. These cooperative locks do
  not prevent unrelated programs from editing the target during application.
  """
  def apply(
        %__MODULE__{} = manager,
        %{
          "workspace_id" => id,
          "revision" => revision,
          "patch_sha256" => patch_sha256,
          "integration" => integration
        }
      )
      when is_binary(patch_sha256) and is_map(integration) do
    locked(manager, id, fn ->
      with {:ok, info} <- applicable(manager, id, revision),
           true <- patch_sha256 == info.workspace["patch_sha256"],
           :ok <- json_map(integration),
           :ok <- integration_supported(manager) do
        target_locked(manager, info.workspace["source"], fn ->
          with {:ok, _} <- patch(manager, id),
               :ok <-
                 backend_verify_apply(
                   manager,
                   info.workspace["source"],
                   integration,
                   info.workspace["patch_path"]
                 ),
               {:ok, attempt} <- activate(manager, info, "apply") do
            apply_dispatched(manager, info, attempt, integration)
          end
        end)
      else
        false -> {:error, :invalid_prepared_patch}
        error -> error
      end
    end)
  end

  def apply(%__MODULE__{}, _), do: {:error, :invalid_prepared_patch}

  defp applicable(manager, id, revision) do
    with {:ok, info} <- expect(manager, id, revision),
         true <- info.status == "frozen" do
      {:ok, info}
    else
      false -> {:error, :workspace_not_applicable}
      error -> error
    end
  end

  defp apply_dispatched(manager, info, attempt, integration) do
    with {:ok, evidence} <-
           backend_apply(
             manager,
             info.workspace["source"],
             integration,
             info.workspace["patch_path"]
           ),
         {:ok, updated} <-
           checkpoint(
             manager,
             info.id,
             attempt,
             "applied",
             Map.put(info.workspace, "application", evidence)
           ) do
      {:ok, updated}
    else
      {:unknown, _} = uncertain -> uncertain
      {:error, reason} -> {:unknown, {:workspace_application_checkpoint_failed, reason}}
    end
  rescue
    error -> {:unknown, {:workspace_application_failed, Exception.message(error)}}
  catch
    kind, reason -> {:unknown, {:workspace_application_failed, kind, reason}}
  end

  defp target_locked(manager, target, fun) do
    path = Path.join([manager.root, "locks", "target-" <> hash(target) <> ".lock"])
    with :ok <- safe_path(path), do: Storage.with_lock(path, [timeout: 2_000], fun)
  end

  @doc "Explicitly discard retained files, including an interrupted attempt, under a revision fence."
  def discard(%__MODULE__{} = manager, id, revision, note) do
    with true <- is_binary(note) and byte_size(note) in 1..4_096 and String.valid?(note) do
      locked(manager, id, fn ->
        with {:ok, info} <- expect(manager, id, revision, false),
             {:ok, attempt} <- activate(manager, info, "discard"),
             path <- Path.join(manager.root, id),
             :ok <- safe_path(path),
             {:ok, _} <- File.rm_rf(path),
             :ok <- DurableLog.sync_directory(manager.root),
             :ok <-
               OperationLog.record_outcome(manager.ledger, id, attempt, :completed, %{
                 "status" => "discarded",
                 "note" => note
               }) do
          get(manager, id)
        end
      end)
    else
      false -> {:error, :workspace_discard_note_required}
    end
  end

  defp create_workspace(manager, workspace) do
    id = workspace["id"]
    attempt = attempt_id()

    with :ok <- OperationLog.record_attempt(manager.ledger, id, attempt),
         :ok <- Storage.ensure_private_dir(Path.dirname(workspace["cwd"]), owned: true),
         :ok <-
           manager.backend.checkout(
             workspace["snapshot"],
             workspace["cwd"],
             manager.backend_options
           ) do
      checkpoint(manager, id, attempt, "ready", workspace)
    end
  end

  defp checkpoint(manager, id, attempt, phase, workspace) do
    with :ok <-
           OperationLog.record_checkpoint(manager.ledger, id, attempt, %{
             "version" => 1,
             "phase" => phase,
             "workspace" => workspace
           }),
         do: get(manager, id)
  end

  defp activate(manager, %{status: status} = info, action)
       when status in ["ready", "worked", "frozen", "applied"] do
    with {:ok, _} <-
           OperationLog.resume_checkpoint(manager.ledger, info.id, info.revision, %{
             "action" => action
           }) do
      attempt = attempt_id()

      with :ok <- OperationLog.record_attempt(manager.ledger, info.id, attempt),
           do: {:ok, attempt}
    end
  end

  defp activate(manager, %{status: status, id: id}, "discard")
       when status in ["intended", "pending_action"] do
    attempt = attempt_id()
    with :ok <- OperationLog.record_attempt(manager.ledger, id, attempt), do: {:ok, attempt}
  end

  defp activate(manager, %{status: "in_progress", id: id}, "discard") do
    with {:ok, %{current_attempt: attempt}} <- OperationLog.recovery(manager.ledger, id),
         do: {:ok, attempt}
  end

  defp activate(_manager, _info, _action), do: {:error, :workspace_requires_review}

  defp expect(manager, id, revision, check_backend? \\ true) do
    with {:ok, info} <- get(manager, id),
         true <- info.revision == revision,
         true <- is_binary(info.workspace["source"]),
         true <- info.workspace["cwd"] == Path.join([manager.root, id, "checkout"]),
         true <-
           not check_backend? or info.workspace["backend_fingerprint"] == fingerprint(manager),
         :ok <- safe_path(info.workspace["cwd"]) do
      {:ok, info}
    else
      false -> {:error, :stale_workspace}
      {:error, _} = error -> error
    end
  end

  defp view(%{
         status: {:checkpointed, %{"version" => 1, "phase" => phase, "workspace" => workspace}, _}
       }),
       do: {phase, workspace}

  defp view(%{status: {:decided, :completed, %{"status" => "discarded"}}, recovery: workspace}),
    do: {"discarded", workspace}

  defp view(%{status: {:intended}, checkpoint: %{"workspace" => workspace}}),
    do: {"pending_action", workspace}

  defp view(%{status: {:intended}, recovery: workspace}), do: {"intended", workspace}
  defp view(%{checkpoint: %{"workspace" => workspace}}), do: {"in_progress", workspace}
  defp view(%{recovery: workspace}), do: {"in_progress", workspace}

  defp locked(manager, id, fun) do
    with :ok <- valid_id(id),
         :ok <- safe_path(manager.root),
         :ok <- Storage.ensure_private_dir(manager.root, owned: true),
         path <- Path.join([manager.root, "locks", id <> ".lock"]),
         :ok <- safe_path(path) do
      Storage.with_lock(path, [timeout: 2_000], fun)
    end
  end

  defp separate_root(root, source) when is_binary(source) do
    with :ok <- safe_path(root), :ok <- safe_path(source) do
      if root == source or String.starts_with?(root, source <> "/"),
        do: {:error, :workspace_state_inside_source},
        else: :ok
    end
  end

  defp separate_root(_, _), do: {:error, :invalid_workspace_source}

  defp normalize_snapshot(%Snapshot{source: source, metadata: metadata})
       when is_binary(source) and is_map(metadata) do
    with :ok <- json_map(metadata), :ok <- separate_root_for_snapshot(source) do
      {:ok, %Snapshot{source: Path.expand(source), metadata: metadata}}
    end
  end

  # Keep accepting persisted/raw provider snapshots while callers migrate to
  # the explicit source/metadata wrapper. New providers should omit `source`
  # from their metadata so the manager does not depend on provider fields.
  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    with source when is_binary(source) <- snapshot["source"],
         :ok <- json_map(snapshot),
         :ok <- separate_root_for_snapshot(source) do
      {:ok, %Snapshot{source: Path.expand(source), metadata: snapshot}}
    else
      _ -> {:error, :invalid_workspace_snapshot}
    end
  end

  defp normalize_snapshot(_), do: {:error, :invalid_workspace_snapshot}

  defp separate_root_for_snapshot(source) do
    if Path.expand(source) == source and source != "" and safe_path(source) == :ok,
      do: :ok,
      else: {:error, :invalid_workspace_source}
  end

  defp integration_supported(%__MODULE__{backend: backend}) do
    callbacks = [prepare_apply: 4, verify_apply: 4, apply: 4]

    if Enum.all?(callbacks, fn {function, arity} ->
         function_exported?(backend, function, arity)
       end) do
      :ok
    else
      {:error, :workspace_integration_unsupported}
    end
  end

  defp backend_prepare_apply(manager, source, patch_path, patch_sha256) do
    manager.backend.prepare_apply(
      source,
      patch_path,
      patch_sha256,
      manager.backend_options
    )
  rescue
    error -> {:error, {:workspace_integration_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:workspace_integration_failed, kind, reason}}
  end

  defp backend_verify_apply(manager, source, integration, patch_path) do
    manager.backend.verify_apply(source, integration, patch_path, manager.backend_options)
  rescue
    error -> {:error, {:workspace_integration_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:workspace_integration_failed, kind, reason}}
  end

  defp backend_apply(manager, source, integration, patch_path) do
    manager.backend.apply(source, integration, patch_path, manager.backend_options)
  rescue
    error -> {:unknown, {:workspace_application_failed, Exception.message(error)}}
  catch
    kind, reason -> {:unknown, {:workspace_application_failed, kind, reason}}
  end

  @doc false
  def safe_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, prefix} ->
      next = if prefix == "" and part == "/", do: "/", else: Path.join(prefix, part)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :workspace_path_symlink}}
        {:ok, _} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp valid_identity(%{root_run_id: root, path: path} = value) do
    if map_size(value) == 2 and is_binary(root) and byte_size(root) in 1..256 and
         String.valid?(root) and is_list(path) and length(path) <= 64 and
         Enum.all?(path, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1))),
       do: :ok,
       else: {:error, :invalid_workspace_owner}
  end

  defp valid_identity(_), do: {:error, :invalid_workspace_owner}

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(~r/\Aws-[0-9a-f]{64}\z/, id), do: :ok, else: {:error, :invalid_workspace_id}
  end

  defp valid_id(_), do: {:error, :invalid_workspace_id}

  defp json_map(value) when is_map(value) do
    encoded = JSON.encode!(value)

    if byte_size(encoded) <= 32_000 and JSON.decode!(encoded) == value,
      do: :ok,
      else: {:error, :invalid_workspace_snapshot}
  rescue
    _ -> {:error, :invalid_workspace_snapshot}
  end

  defp json_map(_), do: {:error, :invalid_workspace_snapshot}

  defp read_bounded(path, max) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case IO.binread(io, max + 1) do
          :eof -> {:ok, ""}
          bytes when is_binary(bytes) and byte_size(bytes) <= max -> {:ok, bytes}
          bytes when is_binary(bytes) -> {:error, :workspace_patch_too_large}
          {:error, _} = error -> error
        end
      after
        File.close(io)
      end
    end
  end

  defp fingerprint(manager),
    do:
      hash(
        :erlang.term_to_binary(
          {manager.backend, manager.backend.module_info(:md5), manager.backend_options}
        )
      )

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp attempt_id, do: "wa-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
