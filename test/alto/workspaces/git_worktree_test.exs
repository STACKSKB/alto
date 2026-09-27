defmodule Alto.Workspaces.GitWorktreeTest do
  use ExUnit.Case, async: true
  alias Alto.{Workspaces, OperationLog}
  alias Alto.Workspaces.{Git, GitWorktree}
  alias Alto.Tools.CreateWorktree

  setup do
    root = Path.join(System.tmp_dir!(), "alto-linked-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "-q"])
    git!(source, ["config", "user.name", "Alto Test"])
    git!(source, ["config", "user.email", "alto@example.test"])
    File.write!(Path.join(source, "tracked.txt"), "base\n")
    commit!(source)
    ledger_opts = [id: "linked", name: nil, dir: Path.join(root, "ledger")]
    ledger = start_supervised!({OperationLog, ledger_opts})

    manager =
      Workspaces.new(root: Path.join(root, "workspaces"), ledger: ledger, backend: GitWorktree)

    context = %{session_id: "test", cwd: source}
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, source: source, manager: manager, context: context, ledger_opts: ledger_opts}
  end

  test "tool freezes its commit before approval, creates once and preserves dirty source", c do
    assert {:ok, prepared, details} =
             CreateWorktree.prepare(%{"name" => "task"}, c.context, manager: c.manager)

    old_head = String.trim(git!(c.source, ["rev-parse", "HEAD"]))
    assert details["base_commit"] == old_head
    refute File.exists?(c.manager.root)

    File.write!(Path.join(c.source, "tracked.txt"), "next commit\n")
    commit!(c.source)
    File.write!(Path.join(c.source, "tracked.txt"), "uncommitted\n")
    File.write!(Path.join(c.source, "untracked.txt"), "keep me\n")
    assert {:ok, result} = CreateWorktree.run(prepared, c.context, [])
    assert {:ok, ^result} = CreateWorktree.run(prepared, c.context, [])
    assert File.read!(Path.join(result["cwd"], "tracked.txt")) == "base\n"
    assert String.trim(git!(result["cwd"], ["rev-parse", "HEAD"])) == old_head
    assert {_, 1} = System.cmd("git", ["symbolic-ref", "-q", "HEAD"], cd: result["cwd"])
    assert File.read!(Path.join(c.source, "tracked.txt")) == "uncommitted\n"
    assert File.read!(Path.join(c.source, "untracked.txt")) == "keep me\n"
    assert git!(c.source, ["worktree", "list", "--porcelain"]) =~ result["cwd"]
  end

  test "linked sources capture patches and apply back without sharing the index", c do
    linked = Path.join(c.root, "linked-source")
    git!(c.source, ["worktree", "add", "--detach", linked, "HEAD"])
    assert {:error, :ordinary_repository_required} = Git.snapshot(linked)
    assert {:ok, snapshot} = Workspaces.prepare(c.manager, linked)
    assert {:ok, info} = Workspaces.create(c.manager, snapshot, owner("child"))
    File.write!(Path.join(info.workspace["cwd"], "new.txt"), "child\n")
    assert {:ok, frozen} = Workspaces.freeze(c.manager, info.id, info.revision)
    assert {:ok, patch} = Workspaces.patch(c.manager, info.id)
    assert patch =~ "+child"
    assert git!(linked, ["status", "--porcelain"]) == ""
    assert {:ok, prepared} = Workspaces.prepare_apply(c.manager, info.id, frozen.revision)
    assert {:ok, applied} = Workspaces.apply(c.manager, prepared)
    assert applied.status == "applied"
    assert File.read!(Path.join(linked, "new.txt")) == "child\n"
    refute File.exists?(Path.join(c.source, "new.txt"))
  end

  test "named branch creation respects collisions and explicit discard unregisters only its worktree",
       c do
    assert {:ok, snapshot} = Workspaces.prepare(c.manager, c.source, branch: "feature/local")
    assert {:ok, info} = Workspaces.create(c.manager, snapshot, owner("branch"))
    cwd = info.workspace["cwd"]
    assert String.trim(git!(cwd, ["branch", "--show-current"])) == "feature/local"
    assert {:error, _} = Workspaces.create(c.manager, snapshot, owner("collision"))
    File.write!(Path.join(cwd, "untracked.txt"), "discard explicitly\n")

    assert {:ok, discarded} =
             Workspaces.discard(c.manager, info.id, info.revision, "user requested removal")

    assert discarded.status == "discarded"
    refute File.exists?(cwd)
    refute git!(c.source, ["worktree", "list", "--porcelain"]) =~ cwd
    assert git!(c.source, ["branch", "--list", "feature/local"]) =~ "feature/local"
    assert File.read!(Path.join(c.source, "tracked.txt")) == "base\n"
  end

  test "cleanup recovers a missing checkout and prevents staging through a forged pointer", c do
    assert {:ok, snapshot} = Workspaces.prepare(c.manager, c.source)
    assert {:ok, first} = Workspaces.create(c.manager, snapshot, owner("first"))
    assert {:ok, second} = Workspaces.create(c.manager, snapshot, owner("second"))
    pointer = Path.join(first.workspace["cwd"], ".git")
    original = File.read!(pointer)
    File.write!(pointer, File.read!(Path.join(second.workspace["cwd"], ".git")))
    File.write!(Path.join(first.workspace["cwd"], "attack.txt"), "not staged\n")

    assert {:error, :invalid_git_pointer} =
             GitWorktree.diff(snapshot.metadata, first.workspace["cwd"])

    assert git!(second.workspace["cwd"], ["status", "--porcelain"]) == ""
    File.write!(pointer, original)
    File.rm_rf!(first.workspace["cwd"])

    assert {:ok, _} =
             Workspaces.discard(c.manager, first.id, first.revision, "recover missing checkout")

    refute git!(c.source, ["worktree", "list", "--porcelain"]) =~ first.workspace["cwd"]
    assert git!(c.source, ["worktree", "list", "--porcelain"]) =~ second.workspace["cwd"]
  end

  test "retained workspace resumes after ledger restart with the same cwd and revision", c do
    assert {:ok, snapshot} = Workspaces.prepare(c.manager, c.source)
    assert {:ok, info} = Workspaces.create(c.manager, snapshot, owner("resume"))

    assert {:ok, :suspended, worked} =
             Workspaces.use(c.manager, info.id, info.revision, fn ws ->
               File.write!(Path.join(ws["cwd"], "progress.txt"), "progress\n")
               :suspended
             end)

    stop_supervised!(OperationLog)
    manager = %{c.manager | ledger: start_supervised!({OperationLog, c.ledger_opts})}

    assert {:ok, cwd, resumed} =
             Workspaces.resume(manager, info.id, worked.revision, fn ws ->
               assert File.read!(Path.join(ws["cwd"], "progress.txt")) == "progress\n"
               ws["cwd"]
             end)

    assert cwd == info.workspace["cwd"]
    assert resumed.revision > worked.revision
  end

  test "cleanup cannot bypass the linked backend and can retire failed creation leftovers", c do
    assert {:ok, snapshot} = Workspaces.prepare(c.manager, c.source)
    assert {:ok, info} = Workspaces.create(c.manager, snapshot, owner("cleanup"))
    wrong = %{c.manager | backend: Git}

    assert {:error, :workspace_backend_mismatch} =
             Workspaces.discard(wrong, info.id, info.revision, "wrong backend")

    assert {:ok, ^info} = Workspaces.get(c.manager, info.id)
    assert File.exists?(info.workspace["cwd"])

    # A failed add can leave an ordinary directory without Git registration.
    git!(c.source, ["worktree", "remove", info.workspace["cwd"]])
    File.mkdir_p!(info.workspace["cwd"])
    File.write!(Path.join(info.workspace["cwd"], "partial"), "incomplete checkout")

    assert {:ok, _} =
             Workspaces.discard(c.manager, info.id, info.revision, "partial checkout reviewed")

    refute File.exists?(info.workspace["cwd"])

    clone = %{c.manager | backend: Git}
    assert {:ok, clone_snapshot} = Workspaces.prepare(clone, c.source)
    assert {:ok, cloned} = Workspaces.create(clone, clone_snapshot, owner("clone"))
    assert {:ok, _} = Workspaces.discard(clone, cloned.id, cloned.revision, "unused clone")
    refute File.exists?(cloned.workspace["cwd"] <> ".git")
  end

  test "invalid refs, filters, bounds and symlink paths fail before checkout", c do
    assert {:error, _} = Workspaces.prepare(c.manager, c.source, ref: "--all")
    assert {:error, _} = Workspaces.prepare(c.manager, c.source, branch: "../bad")
    assert {:error, :checkout_too_large} = GitWorktree.snapshot(c.source, max_checkout_bytes: 1)
    symlink = Path.join(c.root, "link")
    File.ln_s!(c.source, symlink)
    assert {:error, :symlink_unsupported} = GitWorktree.snapshot(symlink)
    git!(c.source, ["config", "filter.test.clean", "false"])
    assert {:error, :source_filters_unsupported} = GitWorktree.snapshot(c.source)

    assert {:error, :invalid_worktree_arguments} =
             CreateWorktree.prepare(%{"name" => "x", "path" => "/tmp/arbitrary"}, c.context,
               manager: c.manager
             )
  end

  defp owner(name), do: %{root_run_id: "test", path: [name]}

  defp commit!(source) do
    git!(source, ["add", "--all"])
    git!(source, ["commit", "-qm", "change"])
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end
end
