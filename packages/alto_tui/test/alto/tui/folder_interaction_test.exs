defmodule Alto.TUI.FolderInteractionTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Menu
  alias ExRatatui.Event.Key

  test "native form editing preserves shifted Unicode and excludes command modifiers" do
    form =
      Menu.form(:workspace_form, "Folder", [{:path, "Folder", "", []}],
        buttons: [],
        on_action: fn state, _ -> state end
      )

    for code <- ["A", "_", "~", "!", "É"] do
      {:edit, _} = Menu.key(form, %Key{code: code, modifiers: ["shift"]})
    end

    assert Menu.value(form, :path) == "A_~!É"

    for modifiers <- [["ctrl"], ["alt"], ["super"], ["ctrl", "shift"]] do
      {:edit, _} = Menu.key(form, %Key{code: "X", modifiers: modifiers})
      assert Menu.value(form, :path) == "A_~!É"
    end

    {:edit, cleared} = Menu.key(form, %Key{code: "u", modifiers: ["ctrl"]})
    assert Menu.value(cleared, :path) == ""
  end

  test "folder suggestions and every action are reachable with keyboard navigation" do
    root = temporary_folders(["alpha", "another"])
    form = folder_form(root)
    {:edit, first} = Menu.key(form, %Key{code: "down"})
    assert first.suggestion_index == 0
    {:edit, second} = Menu.key(first, %Key{code: "down"})
    assert second.suggestion_index == 1

    final =
      Enum.reduce([:submit, :cancel, :choose, :create], second, fn action, menu ->
        {:edit, next} = Menu.key(menu, %Key{code: "down"})
        assert next.suggestion_index == nil
        assert Menu.selected(next).label == Atom.to_string(action)
        assert Menu.key(next, %Key{code: "enter"}) == :select
        assert Menu.selected(next).action.(%{}) == action
        next
      end)

    {:edit, path} = Menu.key(final, %Key{code: "down"})
    assert path.index == 0
    assert path.suggestion_index == nil
    {:edit, create} = Menu.key(path, %Key{code: "back_tab"})
    assert Menu.selected(create).label == "create"
    {:edit, choose} = Menu.key(create, %Key{code: "up"})
    assert Menu.selected(choose).label == "choose"
  end

  test "Tab completes suggestions and then traverses all actions without trapping focus" do
    root = temporary_folders(["alpha"])
    form = folder_form(root)
    {:edit, open} = Menu.key(form, %Key{code: "tab"})
    assert open.index == 1
    assert Menu.value(open, :path) == ""
    {:edit, cancel} = Menu.key(open, %Key{code: "tab"})
    assert Menu.selected(cancel).label == "cancel"

    {:edit, selected} = Menu.key(form, %Key{code: "down"})
    {:edit, completed} = Menu.key(selected, %Key{code: "tab"})
    assert Menu.value(completed, :path) == root <> "/alpha/"
    assert completed.index == 0
    assert completed.suggestion_index == nil
    assert completed.completion == nil
    {:edit, open} = Menu.key(completed, %Key{code: "tab"})
    assert open.index == 1
    assert Menu.selected(open).label == "submit"

    final =
      Enum.reduce(["cancel", "choose", "create"], open, fn label, menu ->
        {:edit, next} = Menu.key(menu, %Key{code: "tab"})
        assert Menu.selected(next).label == label
        next
      end)

    {:edit, path} = Menu.key(final, %Key{code: "tab"})
    assert path.index == 0
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

  defp folder_form(root) do
    Menu.form(:workspace_form, "Folder", [{:path, "Folder", "", []}],
      base: root,
      buttons: ["submit", "cancel", "choose", "create"],
      actions: [:submit, :cancel, :choose, :create],
      on_action: fn _, action -> action end
    )
  end

  defp temporary_folders(folders) do
    root = Path.join(System.tmp_dir!(), "alto-prefix-#{System.unique_integer([:positive])}")
    Enum.each(folders, &File.mkdir_p!(Path.join(root, &1)))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
