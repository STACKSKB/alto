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

  test "list_files uses the host entry limit and rejects malformed options", %{
    root: root,
    context: context
  } do
    for name <- ~w(a b c), do: File.write!(Path.join(root, name), name)

    assert {:ok, %{entries: entries, truncated: true}} =
             ListFiles.run(%{}, context, max_entries: 2)

    assert length(entries) == 2

    assert {:ok, %{entries: entries, truncated: false}} =
             ListFiles.run(%{}, context, max_entries: 5)

    assert length(entries) == 3

    assert {:error, {:invalid_list_files_options, _}} =
             ListFiles.run(%{}, context, max_entries: 0)
  end

  test "read_file defaults to and enforces the host byte ceiling", %{root: root, context: context} do
    File.write!(Path.join(root, "sample.txt"), "abcdef")

    assert {:ok, %{content: "abc", truncated: true}} =
             ReadFile.run(%{"path" => "sample.txt"}, context, max_bytes: 3)

    assert {:error, {:invalid_range, 0, 4}} =
             ReadFile.run(%{"path" => "sample.txt", "limit" => 4}, context, max_bytes: 3)

    assert {:ok, %{content: "abcdef", truncated: false}} =
             ReadFile.run(%{"path" => "sample.txt", "limit" => 6}, context, max_bytes: 6)

    assert {:error, {:invalid_read_file_options, _}} =
             ReadFile.run(%{"path" => "sample.txt"}, context, max_bytes: 0)
  end
end
