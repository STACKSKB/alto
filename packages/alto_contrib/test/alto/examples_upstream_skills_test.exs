defmodule Alto.Examples.UpstreamSkillsTest do
  use ExUnit.Case, async: true
  Code.require_file("../../../../examples/upstream_skills/lib/upstream_skills.ex", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-upstream-skills-#{System.unique_integer([:positive])}")

    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "example/scripts"))
    File.mkdir_p!(Path.join(source, "example/references"))
    File.write!(Path.join(source, ".gitignore"), "*.generated\n")

    File.write!(
      Path.join(source, "example/SKILL.md"),
      "---\nname: example\ndescription: Fixture\n---\nRead {baseDir}/references/guide.md.\n"
    )

    File.write!(Path.join(source, "example/references/guide.md"), "original supporting guide\n")

    File.write!(
      Path.join(source, "example/scripts/helper.sh"),
      "#!/bin/sh\ntouch '#{root}/executed'\n"
    )

    File.chmod!(Path.join(source, "example/scripts/helper.sh"), 0o755)
    git!(source, ["init", "--quiet"])
    git!(source, ["add", "."])
    git!(source, ["commit", "--quiet", "-m", "original"])
    commit = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    destination = Path.join(root, "skills")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, source: source, commit: commit, destination: destination}
  end

  test "fetches the pinned whole tree and composes existing prompt/read tools without execution",
       ctx do
    File.write!(
      Path.join(ctx.source, "example/references/guide.md"),
      "newer unselected version\n"
    )

    git!(ctx.source, ["commit", "--quiet", "-am", "newer"])
    assert {:ok, checkout} = UpstreamSkills.fetch(ctx.source, ctx.commit, ctx.destination)
    assert {:ok, [skill]} = UpstreamSkills.load(checkout, ctx.commit, ["example"])
    assert UpstreamSkills.prompt([skill]) =~ "#{checkout}/example/references/guide.md"
    assert File.exists?(Path.join(checkout, "example/scripts/helper.sh"))
    refute File.exists?(Path.join(ctx.root, "executed"))

    result =
      Alto.Contrib.run(%{"path" => "skills/example/references/guide.md"},
        cwd: ctx.root,
        tools: [Alto.Contrib.Tools.ReadFile],
        loop: Alto.rule_loop(steps: ["read_file"])
      )

    assert result.status == :ok
    assert [result] = result.output
    assert result.content == "original supporting guide\n"
    assert {:error, :eexist} = UpstreamSkills.fetch(ctx.source, ctx.commit, ctx.destination)
  end

  test "verification ignores checkout-configured filesystem monitors", ctx do
    assert {:ok, checkout} = UpstreamSkills.fetch(ctx.source, ctx.commit, ctx.destination)
    git!(checkout, ["config", "core.fsmonitor", Path.join(checkout, "example/scripts/helper.sh")])
    assert {:ok, [_]} = UpstreamSkills.load(checkout, ctx.commit, ["example"])
    refute File.exists?(Path.join(ctx.root, "executed"))
  end

  test "rejects moving revisions and credential-bearing fetch errors do not expose their URL",
       ctx do
    assert {:error, :full_commit_required} =
             UpstreamSkills.fetch(ctx.source, "HEAD", ctx.destination)

    refute File.exists?(ctx.destination)

    assert {:error, {:git_failed, :fetch, _}} =
             error =
             UpstreamSkills.fetch(
               "unsupported-protocol://secret@example.invalid/repo",
               ctx.commit,
               ctx.destination
             )

    refute inspect(error) =~ "secret"
  end

  test "rejects modified supporting files, untracked or ignored additions, and index hiding",
       ctx do
    assert {:ok, checkout} = UpstreamSkills.fetch(ctx.source, ctx.commit, ctx.destination)
    support = Path.join(checkout, "example/references/guide.md")
    File.write!(support, "modified\n")
    assert {:error, :dirty_checkout} = UpstreamSkills.load(checkout, ctx.commit, ["example"])
    git!(checkout, ["checkout", "--", "example/references/guide.md"])

    for name <- ["extra.txt", "extra.generated"] do
      path = Path.join([checkout, "example", name])
      File.write!(path, "untracked")
      assert {:error, :dirty_checkout} = UpstreamSkills.load(checkout, ctx.commit, ["example"])
      File.rm!(path)
    end

    git!(checkout, ["update-index", "--assume-unchanged", "example/references/guide.md"])
    File.write!(support, "hidden edit\n")

    assert {:error, :unsupported_index_flags} =
             UpstreamSkills.load(checkout, ctx.commit, ["example"])
  end

  test "rejects traversal, linked supporting files, mismatched commits and oversized instructions",
       ctx do
    assert {:ok, checkout} = UpstreamSkills.fetch(ctx.source, ctx.commit, ctx.destination)

    for path <- [
          "../source/example",
          "/example",
          "example/../example",
          ".git",
          "example\\scripts"
        ] do
      assert {:error, :unsafe_skill_path} = UpstreamSkills.load(checkout, ctx.commit, [path])
    end

    assert {:error, :skill_count_limit} =
             UpstreamSkills.load(checkout, ctx.commit, List.duplicate("example", 9))

    assert {:error, :revision_mismatch} =
             UpstreamSkills.load(checkout, String.duplicate("0", 40), ["example"])

    File.write!(Path.join(checkout, "example/SKILL.md"), String.duplicate("x", 32_001))
    git!(checkout, ["commit", "--quiet", "-am", "large skill"])
    large_commit = git!(checkout, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:error, :skill_too_large} = UpstreamSkills.load(checkout, large_commit, ["example"])
    File.ln_s!("/etc/passwd", Path.join(checkout, "example/references/escape"))
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "--quiet", "-m", "linked support"])
    linked_commit = git!(checkout, ["rev-parse", "HEAD"]) |> String.trim()

    assert {:error, :unsupported_repository_entries} =
             UpstreamSkills.load(checkout, linked_commit, ["example"])
  end

  defp git!(cwd, args) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "-C",
          cwd | args
        ],
        stderr_to_stdout: true
      )

    output
  end
end
