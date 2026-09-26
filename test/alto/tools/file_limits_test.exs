defmodule Alto.Tools.FileLimitsTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Context
  alias Alto.Tools.{ListFiles, ReadFile}

  setup do
    root = Path.join(System.tmp_dir!(), "alto-file-limits-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: %Context{session_id: "limits", cwd: root}}
  end

  test "write previews preserve UTF-8 at configured byte boundaries", %{context: context} do
    assert {:ok, _prepared, %{preview: %{content: "a", truncated: true}}} =
             Alto.Tool.prepare(
               Alto.Tools.WriteFile,
               %{"path" => "new.txt", "content" => "a😀"},
               context,
               preview_bytes: 2
             )
  end

  test "list_files uses the host entry limit", %{
    root: root,
    context: context
  } do
    for name <- ~w(a b c), do: File.write!(Path.join(root, name), name)

    assert {:ok, %{entries: entries, truncated: true}} =
             Alto.Tool.run(ListFiles, %{}, context, max_entries: 2)

    assert length(entries) == 2

    assert {:ok, %{entries: entries, truncated: false}} =
             Alto.Tool.run(ListFiles, %{}, context, max_entries: 5)

    assert length(entries) == 3
  end

  test "read_file defaults to and enforces the host byte ceiling", %{root: root, context: context} do
    File.write!(Path.join(root, "sample.txt"), "abcdef")

    assert {:ok, %{content: "abc", truncated: true}} =
             Alto.Tool.run(ReadFile, %{"path" => "sample.txt"}, context, max_bytes: 3)

    assert {:error, %NimbleOptions.ValidationError{key: :limit}} =
             Alto.Tool.run(ReadFile, %{"path" => "sample.txt", "limit" => 4}, context,
               max_bytes: 3
             )

    assert {:ok, %{content: "abcdef", truncated: false}} =
             Alto.Tool.run(ReadFile, %{"path" => "sample.txt", "limit" => 6}, context,
               max_bytes: 6
             )
  end
end
