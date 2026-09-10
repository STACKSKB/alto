defmodule Alto.WorkspacesTest do
  use ExUnit.Case, async: true
  alias Alto.{OperationLog, Workspaces}

  defmodule Backend do
    def snapshot(source, _opts), do: {:ok, %{"source" => source, "base_commit" => "test"}}

    def checkout(_snapshot, path, opts) do
      File.mkdir_p!(path)
      File.write!(Path.join(path, "partial"), "created")

      if opts[:block] do
        send(opts[:owner], {:creating, path})

        receive do
          :continue -> :ok
        end
      end

      :ok
    end

    def diff(_snapshot, _path, _opts), do: {:ok, "reviewed patch\n"}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-workspaces-#{System.unique_integer([:positive])}")
    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    ledger_opts = [id: "resources", name: nil, dir: Path.join(dir, "ledger"), max_ops: 2]
    ledger = start_supervised!({OperationLog, ledger_opts})
    manager = Workspaces.new(root: Path.join(dir, "workspaces"), ledger: ledger, backend: Backend)
    assert {:ok, snapshot} = Workspaces.prepare(manager, source)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{manager: manager, snapshot: snapshot, ledger_opts: ledger_opts, source: source}
  end

  defp owner(path), do: %{root_run_id: "root", path: [path]}

  test "retained resources stay nonterminal, freeze immutably and discard under a revision fence",
       %{manager: m, snapshot: s} do
    assert {:ok, first} = Workspaces.create(m, s, owner("a"))
    assert first.status == "ready"
    assert {:ok, ^first} = Workspaces.create(m, s, owner("a"))

    assert {:ok, :result, worked} =
             Workspaces.use(m, first.id, first.revision, fn ws ->
               File.write!(Path.join(ws["cwd"], "work"), "child change")
               :result
             end)

    assert worked.status == "worked"
    assert {:error, :stale_workspace} = Workspaces.freeze(m, first.id, first.revision)
    assert {:ok, frozen} = Workspaces.freeze(m, worked.id, worked.revision)
    assert frozen.status == "frozen"
    assert {:ok, ^frozen} = Workspaces.create(m, s, owner("a"))
    assert {:ok, "reviewed patch\n"} = Workspaces.patch(m, frozen.id)
    File.write!(frozen.workspace["patch_path"], "changed")
    assert {:error, :workspace_patch_changed} = Workspaces.patch(m, frozen.id)

    assert {:error, :stale_workspace} =
             Workspaces.discard(m, first.id, first.revision, "reviewed")

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(
               %{m | backend_options: [changed: true]},
               frozen.id,
               frozen.revision,
               "reviewed"
             )

    refute File.exists?(frozen.workspace["cwd"])
  end

  test "a crashed creation survives ledger restart and never recreates itself", %{
    manager: m,
    snapshot: s,
    ledger_opts: opts
  } do
    m = %{m | backend_options: [block: true, owner: self()]}

    task =
      Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
        Workspaces.create(m, s, owner("crash"))
      end)

    assert_receive {:creating, path}, 2_000
    id = path |> Path.dirname() |> Path.basename()
    assert {:ok, %{status: "in_progress"}} = Workspaces.get(m, id)
    assert {:error, {:storage_lock_timeout, _, _}} = Workspaces.discard(m, id, 2, "busy")
    Task.shutdown(task, :brutal_kill)
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, opts})
    m = %{m | ledger: ledger}
    assert {:ok, recovered} = Workspaces.get(m, id)
    assert recovered.status == "in_progress"
    assert File.read!(Path.join(path, "partial")) == "created"
    assert {:error, {:workspace_requires_review, ^id}} = Workspaces.create(m, s, owner("crash"))
    refute_receive {:creating, _}, 100

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(m, id, recovered.revision, "interrupted checkout reviewed")

    refute File.exists?(path)
  end

  test "active worker use excludes deletion and a killed worker leaves a reviewable resource", %{
    manager: m,
    snapshot: s
  } do
    assert {:ok, ready} = Workspaces.create(m, s, owner("worker"))
    parent = self()

    task =
      Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
        Workspaces.use(m, ready.id, ready.revision, fn ws ->
          File.write!(Path.join(ws["cwd"], "work"), "in progress")
          send(parent, :using_workspace)

          receive do
            :finish -> :done
          end
        end)
      end)

    assert_receive :using_workspace, 2_000
    assert {:ok, active} = Workspaces.get(m, ready.id)
    assert active.status == "in_progress"

    assert {:error, {:storage_lock_timeout, _, _}} =
             Workspaces.discard(m, ready.id, active.revision, "busy")

    Task.shutdown(task, :brutal_kill)
    assert {:error, :workspace_not_freezable} = Workspaces.freeze(m, ready.id, active.revision)

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(m, ready.id, active.revision, "cancelled worker inspected")
  end

  test "held checkpoints cannot be evicted to admit another workspace", %{manager: m, snapshot: s} do
    assert {:ok, a} = Workspaces.create(m, s, owner("a"))
    assert {:ok, b} = Workspaces.create(m, s, owner("b"))
    assert {:error, :ledger_full} = Workspaces.create(m, s, owner("c"))
    assert {:ok, %{status: "ready"}} = Workspaces.get(m, a.id)
    assert {:ok, %{status: "ready"}} = Workspaces.get(m, b.id)
    assert {:ok, _} = Workspaces.discard(m, a.id, a.revision, "unused")
    assert {:ok, %{status: "ready"}} = Workspaces.create(m, s, owner("c"))
  end

  test "a crash between continuation grant and dispatch never recreates the checkout", %{
    manager: m,
    snapshot: s
  } do
    assert {:ok, ready} = Workspaces.create(m, s, owner("grant-gap"))
    File.write!(Path.join(ready.workspace["cwd"], "partial"), "preserve")

    assert {:ok, _} =
             OperationLog.resume_checkpoint(m.ledger, ready.id, ready.revision, %{
               "action" => "use"
             })

    assert {:ok, pending} = Workspaces.get(m, ready.id)
    assert pending.status == "pending_action"
    assert {:error, {:workspace_requires_review, _}} = Workspaces.create(m, s, owner("grant-gap"))
    assert File.read!(Path.join(ready.workspace["cwd"], "partial")) == "preserve"

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(m, ready.id, pending.revision, "unused continuation reviewed")
  end

  test "a ledger failure after work preserves the callback result for accounting", %{
    manager: m,
    snapshot: s
  } do
    assert {:ok, ready} = Workspaces.create(m, s, owner("ledger-failure"))

    assert {:error, {:workspace_checkpoint_failed, _}, :completed_work} =
             Workspaces.use(m, ready.id, ready.revision, fn _ ->
               GenServer.stop(m.ledger)
               :completed_work
             end)
  end

  test "state inside the source and symlinked state paths are rejected", %{
    manager: m,
    source: source
  } do
    assert {:error, :workspace_state_inside_source} =
             Workspaces.prepare(%{m | root: Path.join(source, "state")}, source)

    link = m.root <> "-link"
    File.ln_s!(source, link)
    assert {:error, :workspace_path_symlink} = Workspaces.prepare(%{m | root: link}, source)
  end
end
