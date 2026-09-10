defmodule Alto.Workspaces.GitTest do
  use ExUnit.Case, async: false

  alias Alto.Workspaces.Git

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-workspace-git-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, repo: repo}
  end

  test "clones an independent pinned checkout and emits new-file diff", %{root: root, repo: repo} do
    assert {:ok, snapshot} = Git.snapshot(repo)
    destination = Path.join(root, "child")
    assert :ok = Git.checkout(snapshot, destination)
    assert File.regular?(Path.join(destination, "README.md"))
    assert File.regular?(destination <> ".git/config")

    File.write!(Path.join(destination, "child.txt"), "child change\n")
    assert {:ok, patch} = Git.diff(snapshot, destination)
    assert patch =~ "child.txt"
    assert patch =~ "+child change"
    assert {:ok, ""} = git_output(repo, ["status", "--porcelain"])
    assert {:ok, head} = git_output(repo, ["rev-parse", "HEAD"])
    assert String.trim(head) == snapshot["base_commit"]

    nested = Path.join(destination, "nested")
    File.mkdir_p!(nested)
    git!(nested, ["init", "--quiet"])
    File.write!(Path.join(nested, "nested.txt"), "nested\n")
    git!(nested, ["add", "nested.txt"])

    git!(nested, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "nested"
    ])

    assert {:error, :submodule_unsupported} = Git.diff(snapshot, destination)
  end

  test "rejects dirty sources, alternates and source symlinks", %{root: root, repo: repo} do
    File.write!(Path.join(repo, "README.md"), "dirty\n")
    assert {:error, :source_dirty} = Git.snapshot(repo)
    File.write!(Path.join(repo, "README.md"), "base\n")
    assert {:ok, _} = Git.snapshot(repo)

    File.mkdir_p!(Path.join(repo, ".git/objects/info"))
    File.write!(Path.join(repo, ".git/objects/info/alternates"), "/tmp/other\n")
    assert {:error, :alternates_unsupported} = Git.snapshot(repo)
    File.rm!(Path.join(repo, ".git/objects/info/alternates"))

    symlink_target = Path.join(root, "outside.txt")
    File.write!(symlink_target, "outside\n")
    File.ln_s!(symlink_target, Path.join(repo, "link.txt"))
    assert {:error, :source_dirty} = Git.snapshot(repo)
    git!(repo, ["add", "link.txt"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "link"
    ])

    assert {:error, :symlink_unsupported} = Git.snapshot(repo)
  end

  test "rejects a tampered separate git pointer without touching source", %{
    root: root,
    repo: repo
  } do
    assert {:ok, snapshot} = Git.snapshot(repo)
    destination = Path.join(root, "child")
    assert :ok = Git.checkout(snapshot, destination)

    File.write!(
      Path.join(destination, ".git"),
      "gitdir: #{Path.join(root, "not-the-child-git")}\n"
    )

    File.write!(Path.join(destination, "new.txt"), "new\n")
    assert {:error, :invalid_git_pointer} = Git.diff(snapshot, destination)
    assert {:ok, ""} = git_output(repo, ["status", "--porcelain"])
  end

  test "rejects committed source gitlinks", %{repo: repo} do
    nested = Path.join(repo, "nested")
    File.mkdir_p!(nested)
    git!(nested, ["init", "--quiet"])
    File.write!(Path.join(nested, "nested.txt"), "nested\n")
    git!(nested, ["add", "nested.txt"])

    git!(
      nested,
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "--quiet",
        "-m",
        "nested"
      ]
    )

    git!(repo, ["add", "nested"])

    git!(
      repo,
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "--quiet",
        "-m",
        "gitlink"
      ]
    )

    assert {:error, :submodule_unsupported} = Git.snapshot(repo)
  end

  test "ignores global filter helpers and inherited filter configuration", %{
    root: root,
    repo: repo
  } do
    home = Path.join(root, "home")
    marker = Path.join(root, "injected-marker")
    helper = Path.join(root, "filter.sh")
    File.mkdir_p!(home)
    File.write!(helper, "#!/bin/sh\nprintf ran > #{marker}\ncat\n")
    File.chmod!(helper, 0o755)

    File.write!(
      Path.join(repo, ".gitattributes"),
      "README.md filter=injected\nglobal.txt filter=global\n"
    )

    File.write!(Path.join(repo, "global.txt"), "global\n")
    git!(repo, ["add", ".gitattributes", "global.txt"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "attributes"
    ])

    File.write!(
      Path.join(home, ".gitconfig"),
      "[filter \"global\"]\n\tclean = #{helper}\n\tsmudge = #{helper}\n"
    )

    previous =
      for key <-
            ~w(HOME GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1),
          into: %{},
          do: {key, System.get_env(key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("HOME", home)
    System.put_env("GIT_CONFIG_COUNT", "2")
    System.put_env("GIT_CONFIG_KEY_0", "filter.injected.clean")
    System.put_env("GIT_CONFIG_VALUE_0", helper)
    System.put_env("GIT_CONFIG_KEY_1", "filter.injected.smudge")
    System.put_env("GIT_CONFIG_VALUE_1", helper)

    assert {:ok, snapshot} = Git.snapshot(repo)
    destination = Path.join(root, "clean-config-child")
    assert :ok = Git.checkout(snapshot, destination)
    File.write!(Path.join(destination, "README.md"), "changed\n")
    File.write!(Path.join(destination, "global.txt"), "changed global\n")
    assert {:ok, patch} = Git.diff(snapshot, destination)
    assert patch =~ "+changed global"
    refute File.exists?(marker)
  end

  test "source-local filters are rejected before a status check can execute them", %{
    root: root,
    repo: repo
  } do
    marker = Path.join(root, "local-marker")
    helper = Path.join(root, "local-filter.sh")
    File.write!(helper, "#!/bin/sh\nprintf ran > #{marker}\ncat\n")
    File.chmod!(helper, 0o755)
    File.write!(Path.join(repo, ".gitattributes"), "README.md filter=local\n")
    git!(repo, ["config", "filter.local.clean", helper])
    File.write!(Path.join(repo, "README.md"), "changed\n")
    assert {:error, :source_filters_unsupported} = Git.snapshot(repo)
    refute File.exists?(marker)
  end

  test "source, checkout and patch limits reject oversized data", %{root: root, repo: repo} do
    assert {:error, :source_too_large} = Git.snapshot(repo, max_source_bytes: 1)
    assert {:error, :checkout_too_large} = Git.snapshot(repo, max_checkout_bytes: 1)
    assert {:ok, snapshot} = Git.snapshot(repo)
    destination = Path.join(root, "bounded-child")
    assert :ok = Git.checkout(snapshot, destination)
    File.write!(Path.join(destination, "README.md"), "changed\n")
    assert {:error, :git_output_limit} = Git.diff(snapshot, destination, max_patch_bytes: 16)
  end

  test "ignored build caches do not consume checkout bounds or enter captured patches", %{
    root: root,
    repo: repo
  } do
    File.write!(Path.join(repo, ".gitignore"), "cache/\n")
    git!(repo, ["add", ".gitignore"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "ignore cache"
    ])

    File.mkdir_p!(Path.join(repo, "cache"))
    File.write!(Path.join(repo, "cache/large"), String.duplicate("x", 100_000))
    File.ln_s!(root, Path.join(repo, "cache/link"))
    assert {:ok, snapshot} = Git.snapshot(repo, max_checkout_bytes: 1_000)
    destination = Path.join(root, "ignored-child")
    assert :ok = Git.checkout(snapshot, destination, max_checkout_bytes: 1_000)
    refute File.exists?(Path.join(destination, "cache"))
    File.mkdir_p!(Path.join(destination, "cache"))
    File.write!(Path.join(destination, "cache/large"), String.duplicate("x", 100_000))
    File.write!(Path.join(destination, "README.md"), "child change\n")
    assert {:ok, patch} = Git.diff(snapshot, destination, max_checkout_bytes: 1_000)
    assert patch =~ "+child change"
    refute patch =~ "cache"
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git failed #{status}: #{output}")
    end
  end

  defp git_output(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end
end
