defmodule Alto.Workspaces.ApplyTest do
  use ExUnit.Case, async: true
  alias Alto.{OperationLog, Workspaces}

  setup do
    root = Path.join(System.tmp_dir!(), "alto-apply-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "-q"])
    File.write!(Path.join(source, "a"), "a\n")
    File.write!(Path.join(source, "b"), "b\n")
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "base"
    ])

    opts = [id: "patch-resources", name: nil, dir: Path.join(root, "ledger")]
    ledger = start_supervised!({OperationLog, opts})
    manager = Workspaces.new(root: Path.join(root, "workspaces"), ledger: ledger)
    {:ok, snapshot} = Workspaces.prepare(manager, source)
    on_exit(fn -> File.rm_rf!(root) end)
    %{manager: manager, snapshot: snapshot, source: source, opts: opts}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end

  defp frozen(m, s, name, contents) do
    {:ok, ready} = Workspaces.create(m, s, %{root_run_id: "team", path: [name]})

    {:ok, :ok, worked} =
      Workspaces.use(m, ready.id, ready.revision, fn ws ->
        File.write!(Path.join(ws["cwd"], name), contents)
      end)

    {:ok, result} = Workspaces.freeze(m, ready.id, worked.revision)
    result
  end

  test "two captured workers integrate without staging or replay, and survive ledger restart",
       c do
    a = frozen(c.manager, c.snapshot, "a", "A\n")
    b = frozen(c.manager, c.snapshot, "b", "B\n")
    index = File.read!(Path.join(c.source, ".git/index"))
    assert {:ok, pa} = Workspaces.prepare_apply(c.manager, a.id, a.revision)
    assert {:ok, pb} = Workspaces.prepare_apply(c.manager, b.id, b.revision)
    assert {:ok, ^a} = Workspaces.get(c.manager, a.id)
    assert File.read!(Path.join(c.source, "a")) == "a\n"
    # Approval packets are portable and remain valid in a new ledger process.
    pa = JSON.decode!(JSON.encode!(pa))
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, c.opts})
    m = %{c.manager | ledger: ledger}
    assert {:ok, applied_a} = Workspaces.apply(m, pa)
    assert applied_a.status == "applied"
    assert {:ok, applied_b} = Workspaces.apply(m, pb)
    assert applied_b.status == "applied"
    assert File.read!(Path.join(c.source, "a")) == "A\n"
    assert File.read!(Path.join(c.source, "b")) == "B\n"
    assert File.read!(Path.join(c.source, ".git/index")) == index
    assert {:error, :stale_workspace} = Workspaces.apply(m, pa)
    assert {:ok, patch} = Workspaces.patch(m, a.id)
    assert patch =~ "+A"
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, c.opts})
    m = %{m | ledger: ledger}
    assert {:ok, ^applied_a} = Workspaces.get(m, a.id)

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(m, a.id, applied_a.revision, "integrated")

    assert File.read!(Path.join(c.source, "a")) == "A\n"
  end

  test "a changed target or artifact is refused without advancing the resource", c do
    a = frozen(c.manager, c.snapshot, "a", "A\n")
    assert {:ok, prepared} = Workspaces.prepare_apply(c.manager, a.id, a.revision)
    File.write!(Path.join(c.source, "a"), "operator edit\n")
    assert {:error, :stale_patch_target} = Workspaces.apply(c.manager, prepared)
    assert File.read!(Path.join(c.source, "a")) == "operator edit\n"
    assert {:ok, ^a} = Workspaces.get(c.manager, a.id)
    File.write!(a.workspace["patch_path"], "tampered")
    assert {:error, :workspace_patch_changed} = Workspaces.apply(c.manager, prepared)
    assert {:ok, ^a} = Workspaces.get(c.manager, a.id)
  end

  test "discarding during approval prevents application", c do
    a = frozen(c.manager, c.snapshot, "a", "A\n")
    assert {:ok, prepared} = Workspaces.prepare_apply(c.manager, a.id, a.revision)
    assert {:ok, _} = Workspaces.discard(c.manager, a.id, a.revision, "rejected")
    assert {:error, :stale_workspace} = Workspaces.apply(c.manager, prepared)
    assert File.read!(Path.join(c.source, "a")) == "a\n"
  end

  test "an interrupted apply retains its frozen patch metadata and cannot replay", c do
    a = frozen(c.manager, c.snapshot, "a", "A\n")
    assert {:ok, prepared} = Workspaces.prepare_apply(c.manager, a.id, a.revision)

    assert {:ok, _} =
             OperationLog.resume_checkpoint(c.manager.ledger, a.id, a.revision, %{
               "action" => "apply"
             })

    assert {:ok, pending} = Workspaces.get(c.manager, a.id)
    assert pending.status == "pending_action"
    assert pending.workspace["patch_sha256"] == a.workspace["patch_sha256"]
    assert :ok = OperationLog.record_attempt(c.manager.ledger, a.id, "interrupted")
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, c.opts})
    m = %{c.manager | ledger: ledger}
    assert {:ok, active} = Workspaces.get(m, a.id)
    assert active.status == "in_progress"
    assert {:ok, retained_patch} = Workspaces.patch(m, a.id)
    assert retained_patch =~ "+A"
    assert active.workspace["patch_sha256"] == a.workspace["patch_sha256"]
    assert {:error, :stale_workspace} = Workspaces.apply(m, prepared)

    assert {:error, :workspace_not_applicable} =
             Workspaces.prepare_apply(m, a.id, active.revision)

    assert File.read!(Path.join(c.source, "a")) == "a\n"
  end
end
