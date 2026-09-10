defmodule Alto.Workspaces.GitPatchTest do
  use ExUnit.Case, async: true

  alias Alto.Workspaces.GitPatch

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-git-patch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.test"])
    git!(dir, ["config", "user.name", "GitPatch Test"])
    File.write!(Path.join(dir, "a.txt"), "a\n")
    File.write!(Path.join(dir, "b.txt"), "b\n")
    File.write!(Path.join(dir, "old name.txt"), "rename me\n")
    File.write!(Path.join(dir, "binary.bin"), <<0, 1, 2, 255>>)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end

  defp patch_for(repo, mutate) do
    mutate.()
    git!(repo, ["add", "--all"])
    patch = git!(repo, ["diff", "--cached", "--binary"])
    git!(repo, ["reset", "--hard", "-q", "HEAD"])
    path = Path.join(System.tmp_dir!(), "alto-patch-#{System.unique_integer([:positive])}.diff")
    File.write!(path, patch)
    on_exit(fn -> File.rm(path) end)
    {path, patch}
  end

  defp digest(patch), do: :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower)

  test "prepare is read-only and leaves the index byte-for-byte unchanged", %{dir: dir} do
    {patch_path, patch} =
      patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "changed\n") end)

    before = File.read!(Path.join([dir, ".git", "index"]))
    assert {:ok, manifest} = GitPatch.prepare(dir, patch_path, digest(patch), [])
    assert manifest["patch_sha256"] == digest(patch)
    assert File.read!(Path.join([dir, ".git", "index"])) == before
    assert File.read!(Path.join(dir, "a.txt")) == "a\n"
  end

  test "disjoint patches can be prepared together, verified, and applied", %{dir: dir} do
    {a_path, a_patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "A\n") end)
    {b_path, b_patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "b.txt"), "B\n") end)
    index_before = File.read!(Path.join([dir, ".git", "index"]))
    assert {:ok, a} = GitPatch.prepare(dir, a_path, digest(a_patch), [])
    assert {:ok, b} = GitPatch.prepare(dir, b_path, digest(b_patch), [])
    assert :ok = GitPatch.verify(a, a_path, [])
    assert :ok = GitPatch.verify(b, b_path, [])
    assert {:ok, _} = GitPatch.apply(a, a_path, [])
    assert :ok = GitPatch.verify(b, b_path, [])
    assert {:ok, _} = GitPatch.apply(b, b_path, [])
    assert File.read!(Path.join(dir, "a.txt")) == "A\n"
    assert File.read!(Path.join(dir, "b.txt")) == "B\n"
    assert File.read!(Path.join([dir, ".git", "index"])) == index_before
  end

  test "verify rejects changed content, mode, HEAD, and repository config", %{dir: dir} do
    {path, patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "A\n") end)
    assert {:ok, manifest} = GitPatch.prepare(dir, path, digest(patch), [])
    File.write!(Path.join(dir, "a.txt"), "drift\n")
    assert {:error, :stale_patch_target} = GitPatch.verify(manifest, path, [])

    git!(dir, ["reset", "--hard", "-q", "HEAD"])
    {path, patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "A\n") end)
    {:ok, manifest} = GitPatch.prepare(dir, path, digest(patch), [])
    File.chmod!(Path.join(dir, "a.txt"), 0o755)
    assert {:error, :stale_patch_target} = GitPatch.verify(manifest, path, [])
    File.chmod!(Path.join(dir, "a.txt"), 0o644)

    {path, patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "A\n") end)
    {:ok, manifest} = GitPatch.prepare(dir, path, digest(patch), [])
    git!(dir, ["commit", "--allow-empty", "-qm", "new head"])
    assert {:error, :stale_patch_target} = GitPatch.verify(manifest, path, [])

    {path, patch} = patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "A\n") end)
    {:ok, manifest} = GitPatch.prepare(dir, path, digest(patch), [])
    git!(dir, ["config", "core.autocrlf", "true"])
    assert {:error, :stale_patch_target} = GitPatch.verify(manifest, path, [])
  end

  test "rename, add, delete, binary, and special filenames survive prepare and apply", %{dir: dir} do
    {patch_path, patch} =
      patch_for(dir, fn ->
        git!(dir, ["mv", "old name.txt", "renamed name.txt"])
        File.rm!(Path.join(dir, "b.txt"))
        File.write!(Path.join(dir, "added file.txt"), "added\n")
        File.write!(Path.join(dir, "binary.bin"), <<255, 0, 254, 1>>)
        File.write!(Path.join(dir, "line\nname.txt"), "newline\n")
        File.write!(Path.join(dir, "tab\tname.txt"), "tabbed\n")
      end)

    assert {:ok, manifest} = GitPatch.prepare(dir, patch_path, digest(patch), [])
    assert :ok = GitPatch.verify(manifest, patch_path, [])
    assert {:ok, _evidence} = GitPatch.apply(manifest, patch_path, [])
    assert File.exists?(Path.join(dir, "renamed name.txt"))
    refute File.exists?(Path.join(dir, "old name.txt"))
    refute File.exists?(Path.join(dir, "b.txt"))
    assert File.read!(Path.join(dir, "added file.txt")) == "added\n"
    assert File.read!(Path.join(dir, "binary.bin")) == <<255, 0, 254, 1>>
    assert File.read!(Path.join(dir, "line\nname.txt")) == "newline\n"
    assert File.read!(Path.join(dir, "tab\tname.txt")) == "tabbed\n"
  end

  test "verify rejects a tampered patch without changing the target", %{dir: dir} do
    {patch_path, patch} =
      patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "changed\n") end)

    assert {:ok, manifest} = GitPatch.prepare(dir, patch_path, digest(patch), [])
    File.write!(patch_path, patch <> "\n# tampered\n")
    assert {:error, _reason} = GitPatch.verify(manifest, patch_path, [])
    assert File.read!(Path.join(dir, "a.txt")) == "a\n"
  end

  test "apply reports unknown when the patch disappears after dispatch preparation", %{dir: dir} do
    {patch_path, patch} =
      patch_for(dir, fn -> File.write!(Path.join(dir, "a.txt"), "changed\n") end)

    assert {:ok, manifest} = GitPatch.prepare(dir, patch_path, digest(patch), [])
    File.rm!(patch_path)

    assert {:unknown, {:patch_application_uncertain, _reason}} =
             GitPatch.apply(manifest, patch_path, [])
  end
end
