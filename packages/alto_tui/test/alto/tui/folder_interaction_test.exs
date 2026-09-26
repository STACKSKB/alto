defmodule Alto.TUI.FolderInteractionTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.TextForm
  alias ExRatatui.Event.Key

  test "native form editing preserves shifted Unicode and excludes command modifiers" do
    form = TextForm.new(:workspace_form, "Folder", [{:path, "Folder", "", []}])

    for code <- ["A", "_", "~", "!", "É"] do
      {:edit, _} = TextForm.key(form, %Key{code: code, modifiers: ["shift"]})
    end

    assert TextForm.value(form) == "A_~!É"

    for modifiers <- [["ctrl"], ["alt"], ["super"], ["ctrl", "shift"]] do
      {:edit, _} = TextForm.key(form, %Key{code: "X", modifiers: modifiers})
      assert TextForm.value(form) == "A_~!É"
    end

    {:edit, cleared} = TextForm.key(form, %Key{code: "u", modifiers: ["ctrl"]})
    assert TextForm.value(cleared) == ""
  end

  test "filesystem suggestions exclude files, respect hidden prefixes, and reject multiline paths" do
    root = temporary_folders(["alpha", ".hidden"])
    File.write!(Path.join(root, "a-file"), "not a directory")
    assert {:ok, %{folders: [folder]}} = Alto.Harness.Folders.suggest("a", root)
    assert folder == root <> "/alpha/"
    assert {:ok, %{folders: [hidden]}} = Alto.Harness.Folders.suggest(".", root)
    assert hidden == root <> "/.hidden/"
    assert {:error, _} = Alto.Harness.Folders.suggest("bad\npath", root)
  end

  test "completion considers matches beyond the fifty displayed suggestions" do
    root = temporary_folders(Enum.map(1..55, &("aaa-" <> Integer.to_string(&1))) ++ ["az-last"])

    assert {:ok, %{folders: folders, completion: prefix}} =
             Alto.Harness.Folders.suggest("a", root)

    assert length(folders) == 50
    assert prefix == root <> "/a"
  end

  defp temporary_folders(folders) do
    root = Path.join(System.tmp_dir!(), "alto-prefix-#{System.unique_integer([:positive])}")
    Enum.each(folders, &File.mkdir_p!(Path.join(root, &1)))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
