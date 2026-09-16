defmodule Alto.TUI.WorkspaceFormTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.WorkspaceForm
  alias ExRatatui.Event.Key

  test "folder entry and actions remain visible on narrow terminals" do
    for {width, height} <- [{120, 36}, {50, 16}] do
      form = WorkspaceForm.new("/projects") |> WorkspaceForm.paste("/projects/猫 folder")
      terminal = ExRatatui.init_test_terminal(width, height)

      assert :ok =
               ExRatatui.draw(
                 terminal,
                 WorkspaceForm.widgets(form, %{width: width, height: height})
               )

      screen = ExRatatui.get_buffer_content(terminal)
      assert screen =~ "Open folder"
      assert screen =~ "/projects/猫"
      assert WorkspaceForm.path(form) == "/projects/猫 folder"
      assert screen =~ "[ Open folder ]"
      assert screen =~ "[ Cancel ]"
      rect = WorkspaceForm.rect(width, height)

      assert {:submit, "/projects/猫 folder"} =
               WorkspaceForm.click(form, rect.height - 5, 3, rect.height)

      assert :cancel = WorkspaceForm.click(form, rect.height - 5, 23, rect.height)
    end
  end

  test "suggests directories, highlights choices and completes nested paths with spaces" do
    root = Path.join(System.tmp_dir!(), "alto-folders-#{System.unique_integer([:positive])}")

    for folder <- ["alpha", "another folder/nested", ".hidden"],
        do: File.mkdir_p!(Path.join(root, folder))

    File.write!(Path.join(root, "a-file"), "not a folder")
    on_exit(fn -> File.rm_rf!(root) end)
    form = WorkspaceForm.new(root) |> WorkspaceForm.paste("a")
    assert form.suggestions == [root <> "/alpha/", root <> "/another folder/"]
    {:edit, chosen} = WorkspaceForm.key(form, %Key{code: "down"})
    {:edit, chosen} = WorkspaceForm.key(chosen, %Key{code: "down"})
    assert chosen.suggestion_index == 1
    assert WorkspaceForm.path(chosen) == "a"
    widgets = WorkspaceForm.widgets(chosen, %{width: 100, height: 30})

    assert Enum.any?(widgets, fn
             {%ExRatatui.Widgets.List{selected: 1, highlight_style: %{bg: :light_blue}}, _} ->
               true

             _ ->
               false
           end)

    {:edit, completed} = WorkspaceForm.key(chosen, %Key{code: "tab"})
    assert WorkspaceForm.path(completed) == root <> "/another folder/"
    assert completed.suggestions == [root <> "/another folder/nested/"]
    {:edit, nested} = WorkspaceForm.key(completed, %Key{code: "tab"})
    assert {:submit, path} = WorkspaceForm.key(nested, %Key{code: "enter"})
    assert path == root <> "/another folder/nested/"
    assert {:ok, [hidden]} = Alto.Harness.Folders.complete(".", root)
    assert hidden == root <> "/.hidden/"
    assert {:error, _} = Alto.Harness.Folders.complete("bad\npath", root)
  end

  test "remote forms use supplied service suggestions without reading local folders" do
    form = WorkspaceForm.new("/remote", "the service host", ["/remote/saved"], complete: nil)
    assert form.suggestions == ["/remote/saved/"]
    form = WorkspaceForm.paste(form, "pro")
    assert form.suggestions == []
    form = WorkspaceForm.suggest(form, {:ok, ["/remote/project/"]})
    {:edit, completed} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(completed) == "/remote/project/"
  end
end
