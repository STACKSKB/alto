defmodule Alto.ProjectTest do
  use ExUnit.Case, async: true

  alias Alto.Project

  setup do
    root = Path.join(System.tmp_dir!(), "alto-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "returns nil when no instruction file exists", %{root: root} do
    assert {:ok, nil} = Project.load(root)
  end

  test "prefers alto.md over AGENTS.md", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "generic")
    File.write!(Path.join(root, "alto.md"), "specific")

    assert {:ok, %{file: "alto.md", instructions: "specific", truncated: false}} =
             Project.load(root)
  end

  test "falls back to AGENTS.md", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "generic")

    assert {:ok, %{file: "AGENTS.md", instructions: "generic", truncated: false}} =
             Project.load(root)
  end

  test "truncates oversized instructions on a code-point boundary", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), String.duplicate("a", 31_999) <> "ééé")

    assert {:ok, %{truncated: true, instructions: instructions}} = Project.load(root)
    assert byte_size(instructions) <= Project.max_instruction_bytes()
    assert String.valid?(instructions)
    assert instructions =~ "a"
  end

  test "rejects content that is not valid UTF-8", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), <<0xFF, 0xFE>>)

    assert {:error, {"AGENTS.md", :instructions_not_utf8}} = Project.load(root)
  end

  test "surfaces read failures other than a missing file", %{root: root} do
    file = Path.join(root, "file.txt")
    File.write!(file, "not a directory")

    assert {:error, {"AGENTS.md", :enotdir}} = Project.load(file, files: ["AGENTS.md"])
  end

  test "the candidate file list is configurable", %{root: root} do
    File.write!(Path.join(root, "CLAUDE.md"), "claude")

    assert {:ok, %{file: "CLAUDE.md", instructions: "claude"}} =
             Project.load(root, files: ["CLAUDE.md"])
  end
end
