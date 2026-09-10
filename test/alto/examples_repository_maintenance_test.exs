defmodule Alto.Examples.RepositoryMaintenanceTest do
  use ExUnit.Case, async: true
  import Bitwise

  Code.require_file("../../examples/repository_maintenance/lib/workflow.ex", __DIR__)
  Code.require_file("../../examples/repository_maintenance/lib/webhook_inbox.ex", __DIR__)

  test "failure reports are validated before durable admission" do
    assert :ok =
             RepositoryMaintenance.Workflow.validate_report(%{
               "kind" => "ci_failure",
               "source" => "github",
               "delivery_id" => "delivery-1",
               "commit" => String.duplicate("a", 40),
               "failure" => "mix test failed"
             })

    assert {:error, :invalid_report} =
             RepositoryMaintenance.Workflow.validate_report(%{
               "kind" => "ci_failure",
               "source" => "github",
               "delivery_id" => "delivery-1",
               "commit" => "not-a-sha",
               "failure" => "failed"
             })
  end

  test "a reviewed manifest applies at its recorded clean base" do
    repo =
      Path.join(System.tmp_dir!(), "alto-maintenance-repo-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "old\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=test@example.invalid",
          "-c",
          "user.name=Test",
          "commit",
          "--quiet",
          "-m",
          "base"
        ],
        cd: repo
      )

    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    {tree, 0} = System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: repo)
    base = String.trim(base)
    tree = String.trim(tree)

    patch =
      "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n"

    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-artifacts-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(artifact_dir) end)
    File.mkdir_p!(artifact_dir)
    patch_path = Path.join(artifact_dir, "patch-1.patch")
    manifest_path = Path.join(artifact_dir, "patch-1.json")
    File.write!(patch_path, patch)

    manifest = %{
      "version" => 1,
      "patch_id" => String.duplicate("a", 64),
      "patch_sha256" => sha256(patch),
      "base_commit" => base,
      "base_tree" => tree,
      "patch_path" => patch_path,
      "reviewed" => true
    }

    manifest_json = JSON.encode!(manifest) <> "\n"
    File.write!(manifest_path, manifest_json)

    assert {:ok, ^manifest} =
             RepositoryMaintenance.Workflow.apply_reviewed(
               repo,
               manifest_path,
               sha256(manifest_json)
             )

    assert File.read!(Path.join(repo, "README.md")) == "new\n"
    assert File.read!(Path.join(artifact_dir, manifest["patch_id"] <> ".apply.json")) =~ "applied"
  end

  test "apply rejects an unreviewed manifest and a dirty target" do
    repo =
      Path.join(System.tmp_dir!(), "alto-maintenance-stale-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "old\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=test@example.invalid",
          "-c",
          "user.name=Test",
          "commit",
          "--quiet",
          "-m",
          "base"
        ],
        cd: repo
      )

    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    {tree, 0} = System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: repo)
    base = String.trim(base)
    tree = String.trim(tree)

    patch =
      "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n"

    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-stale-artifacts-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(artifact_dir) end)
    File.mkdir_p!(artifact_dir)
    patch_path = Path.join(artifact_dir, "patch.patch")
    manifest_path = Path.join(artifact_dir, "manifest.json")
    File.write!(patch_path, patch)

    manifest = %{
      "version" => 1,
      "patch_id" => String.duplicate("b", 64),
      "patch_sha256" => sha256(patch),
      "base_commit" => base,
      "base_tree" => tree,
      "patch_path" => patch_path,
      "reviewed" => false
    }

    json = JSON.encode!(manifest) <> "\n"
    File.write!(manifest_path, json)

    assert {:error, :manifest_not_reviewed} =
             RepositoryMaintenance.Workflow.apply_reviewed(repo, manifest_path, sha256(json))

    reviewed_json = JSON.encode!(Map.put(manifest, "reviewed", true)) <> "\n"
    File.write!(manifest_path, reviewed_json)
    File.write!(patch_path, patch <> "# tampered\n")

    assert {:error, :patch_hash_mismatch} =
             RepositoryMaintenance.Workflow.apply_reviewed(
               repo,
               manifest_path,
               sha256(reviewed_json)
             )

    File.write!(patch_path, patch)
    File.write!(Path.join(repo, "README.md"), "operator change\n")

    assert {:error, :stale_tree} =
             RepositoryMaintenance.Workflow.apply_reviewed(
               repo,
               manifest_path,
               sha256(reviewed_json)
             )
  end

  test "new files are included in the reviewed patch while the source stays clean" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-new-file-#{System.unique_integer([:positive])}"
      )

    queue_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-new-file-queue-#{System.unique_integer([:positive])}"
      )

    state_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-new-file-state-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf!(repo)
      File.rm_rf!(queue_dir)
      File.rm_rf!(state_dir)
    end)

    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "base\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=test@example.invalid",
          "-c",
          "user.name=Test",
          "commit",
          "--quiet",
          "-m",
          "base"
        ],
        cd: repo
      )

    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    report = %{
      "kind" => "local_failure",
      "source" => "local",
      "delivery_id" => "new-file",
      "commit" => String.trim(base),
      "failure" => "add a repair note"
    }

    {:ok, queue} =
      Alto.Queue.start_link(
        id: "new-file-#{System.unique_integer([:positive])}",
        dir: queue_dir,
        name: nil
      )

    assert {:ok, _} = RepositoryMaintenance.Workflow.admit(queue, report)

    assert {:ok, manifest} =
             RepositoryMaintenance.Workflow.process(queue, repo,
               state_dir: state_dir,
               diagnoser: fn checkout, _report ->
                 File.write!(Path.join(checkout, "REPAIR.md"), "generated\n")
                 {:ok, %{deterministic: true}}
               end,
               tests: ["sh", "-c", "exit 0"]
             )

    assert File.read!(manifest["patch_path"]) =~ "REPAIR.md"
    assert File.read!(manifest["patch_path"]) =~ "+generated"
    assert {:ok, ""} = git_output(repo, ["status", "--porcelain"])

    report_two = %{report | "delivery_id" => "new-file-2"}
    assert {:ok, _} = RepositoryMaintenance.Workflow.admit(queue, report_two)

    assert {:ok, manifest_two} =
             RepositoryMaintenance.Workflow.process(queue, repo,
               state_dir: state_dir,
               diagnoser: fn checkout, _report ->
                 File.write!(Path.join(checkout, "REPAIR-2.md"), "second\n")
                 {:ok, %{deterministic: true}}
               end,
               tests: ["sh", "-c", "exit 0"]
             )

    assert manifest_two["patch_id"] != manifest["patch_id"]
    assert Path.dirname(manifest_two["manifest_path"]) != Path.dirname(manifest["manifest_path"])
    assert (File.stat!(manifest_two["manifest_path"]).mode &&& 0o077) == 0

    report_three = %{report | "delivery_id" => "new-file-3"}
    assert {:ok, _} = RepositoryMaintenance.Workflow.admit(queue, report_three)

    assert {:ok, manifest_three} =
             RepositoryMaintenance.Workflow.process(queue, repo,
               state_dir: state_dir,
               diagnoser: fn checkout, _report ->
                 File.write!(Path.join(checkout, "REPAIR-2.md"), "second\n")
                 {:ok, %{deterministic: true}}
               end,
               tests: ["sh", "-c", "echo rerun"]
             )

    assert manifest_three["patch_id"] == manifest_two["patch_id"]
    assert manifest_three["manifest_path"] == manifest_two["manifest_path"]
  end

  test "admission is source scoped and survives a queue restart" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-queue-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [id: "maintenance-#{System.unique_integer([:positive])}", dir: dir, name: nil]
    {:ok, queue} = Alto.Queue.start_link(opts)

    report = %{
      "kind" => "local_failure",
      "source" => "local",
      "delivery_id" => "same-report",
      "commit" => String.duplicate("b", 40),
      "failure" => "mix test failed"
    }

    assert {:ok, _} = RepositoryMaintenance.Workflow.admit(queue, report)
    assert {:error, :duplicate} = RepositoryMaintenance.Workflow.admit(queue, report)
    GenServer.stop(queue)
    {:ok, restarted} = Alto.Queue.start_link(opts)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert {:error, :duplicate} = RepositoryMaintenance.Workflow.admit(restarted, report)
    assert %{pending: 1, claimed: 0} = Alto.Queue.count(restarted)
  end

  test "the webhook adapter sends verified JSON through the CLI admission path" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-webhook-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [id: "webhook-#{System.unique_integer([:positive])}", dir: dir, name: nil]
    {:ok, queue} = Alto.Queue.start_link(opts)

    assert :ok =
             RepositoryMaintenance.WebhookInbox.validate_options(queue: queue, source: "github")

    body =
      JSON.encode!(%{
        "kind" => "ci_failure",
        "commit" => String.duplicate("c", 40),
        "failure" => "mix test failed"
      })

    assert {:ok, _} =
             RepositoryMaintenance.WebhookInbox.admit(
               "ignored",
               %{
                 "delivery_id" => "http-1",
                 "body" => body
               },
               queue: queue,
               source: "github"
             )

    assert [%{key: "github:http-1", payload: %{"report" => report}}] =
             Alto.Queue.records(queue)

    assert report["source"] == "github"
    assert report["delivery_id"] == "http-1"
  end

  test "failed tests retain the claimed checkout and an error record" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-failed-#{System.unique_integer([:positive])}"
      )

    queue_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-failed-queue-#{System.unique_integer([:positive])}"
      )

    state_dir =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-failed-state-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf!(repo)
      File.rm_rf!(queue_dir)
      File.rm_rf!(state_dir)
    end)

    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "old\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=test@example.invalid",
          "-c",
          "user.name=Test",
          "commit",
          "--quiet",
          "-m",
          "base"
        ],
        cd: repo
      )

    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    report = %{
      "kind" => "local_failure",
      "source" => "local",
      "delivery_id" => "failed-tests",
      "commit" => String.trim(base),
      "failure" => "repair this file"
    }

    queue_opts = [id: "failed-#{System.unique_integer([:positive])}", dir: queue_dir, name: nil]
    {:ok, queue} = Alto.Queue.start_link(queue_opts)
    assert {:ok, _} = RepositoryMaintenance.Workflow.admit(queue, report)

    assert {:error, {:tests_failed, 7, _output}} =
             RepositoryMaintenance.Workflow.process(queue, repo,
               state_dir: state_dir,
               diagnoser: fn checkout, _report ->
                 File.write!(Path.join(checkout, "README.md"), "changed\n")
                 {:ok, %{deterministic: true}}
               end,
               tests: ["sh", "-c", "exit 7"]
             )

    assert %{pending: 0, claimed: 1} = Alto.Queue.count(queue)
    assert [error] = Path.wildcard(Path.join(state_dir, "errors/*.json"))
    assert String.contains?(File.read!(error), "tests_failed")
    assert [checkout] = Path.wildcard(Path.join(state_dir, "worktrees/*"))
    assert File.exists?(Path.join(checkout, "README.md"))
  end

  test "bounded report reads reject oversized input before decoding" do
    path =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-report-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, String.duplicate("x", 64_001))
    assert {:error, :file_too_large} = RepositoryMaintenance.Workflow.read_bounded(path, 64_000)
  end

  test "state symlinks into the repository are rejected" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-symlink-repo-#{System.unique_integer([:positive])}"
      )

    state_parent =
      Path.join(
        System.tmp_dir!(),
        "alto-maintenance-symlink-parent-#{System.unique_integer([:positive])}"
      )

    state = Path.join(state_parent, "state")

    on_exit(fn ->
      File.rm_rf!(repo)
      File.rm_rf!(state_parent)
    end)

    File.mkdir_p!(repo)
    File.mkdir_p!(state_parent)
    assert :ok = File.ln_s(repo, state)

    assert {:error, :state_dir_symlink} =
             RepositoryMaintenance.Workflow.process(nil, repo, state_dir: state)
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp git_output(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end
end
