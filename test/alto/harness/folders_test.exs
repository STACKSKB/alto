defmodule Alto.Harness.FoldersTest do
  use ExUnit.Case, async: true
  alias Alto.Harness.Folders

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-folder-create-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "creates relative and absolute paths, including missing parents", %{root: root} do
    path = Path.join(root, "Parent/New Folder É!")
    assert {:ok, ^path} = Folders.create("Parent/New Folder É!", root)
    assert File.dir?(path)
    absolute = Path.join(root, "absolute")
    assert {:ok, ^absolute} = Folders.create(absolute, "/unused-base")
    assert File.dir?(absolute)
  end

  test "existing folders/files and invalid paths do not mutate filesystem contents", %{root: root} do
    File.write!(Path.join(root, "file"), "unchanged")
    assert {:error, :folder_already_exists} = Folders.create(root, root)
    assert {:error, :eexist} = Folders.create("file", root)
    assert {:error, :enotdir} = Folders.create("file/child", root)
    assert File.read!(Path.join(root, "file")) == "unchanged"

    for path <- [
          "",
          "  ",
          "new\nfolder",
          "new\tname",
          <<0>>,
          <<255>>,
          String.duplicate("a", 4097),
          nil
        ] do
      assert {:error, :invalid_workspace_path} = Folders.create(path, root)
    end

    assert File.ls!(root) == ["file"]
  end
end
