defmodule Alto.TUI.WorkspaceFormTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.WorkspaceForm
  alias ExRatatui.Event.Key

  test "create action uses typed path, even with a suggestion highlighted" do
    root = temporary_folders(["Alpha"])
    form = WorkspaceForm.new(root) |> WorkspaceForm.paste(root <> "/")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "down"})
    assert {:create, path} = WorkspaceForm.key(form, %Key{code: "n", modifiers: ["ctrl"]})
    assert path == root <> "/"
    assert WorkspaceForm.click(form, 13, 30) == {:create, path}

    terminal = ExRatatui.init_test_terminal(50, 18)
    ExRatatui.draw(terminal, WorkspaceForm.widgets(form, %{width: 50, height: 18}))
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "[ Create folder ]"
    assert screen =~ "^N create & open"
  end

  test "suggestions have no default highlight and Enter opens exactly the typed path" do
    root = temporary_folders(["Alpha", "Beta"])
    form = WorkspaceForm.new(root)
    assert suggestion_list(form).selected == nil
    assert {:submit, ""} = WorkspaceForm.key(form, %Key{code: "enter"})
    form = WorkspaceForm.paste(form, root <> "/")
    assert suggestion_list(form).selected == nil
    assert {:submit, path} = WorkspaceForm.key(form, %Key{code: "enter"})
    assert path == root <> "/"

    for {width, height} <- [{100, 30}, {50, 16}] do
      terminal = ExRatatui.init_test_terminal(width, height)
      ExRatatui.draw(terminal, WorkspaceForm.widgets(form, %{width: width, height: height}))
      assert ExRatatui.get_buffer_content(terminal) =~ "Enter opens typed path"
    end

    {:edit, chosen} = WorkspaceForm.key(form, %Key{code: "down"})
    assert suggestion_list(chosen).selected == 0
    assert {:submit, selected} = WorkspaceForm.key(chosen, %Key{code: "enter"})
    assert selected == root <> "/Alpha/"
    assert WorkspaceForm.click(chosen, 13, 3) == {:submit, selected}
    terminal = ExRatatui.init_test_terminal(50, 16)
    ExRatatui.draw(terminal, WorkspaceForm.widgets(chosen, %{width: 50, height: 16}))
    assert ExRatatui.get_buffer_content(terminal) =~ "Enter opens selected folder"
    assert suggestion_list(form).items == ["  " <> root <> "/Alpha/", "  " <> root <> "/Beta/"]
    assert suggestion_list(chosen).items == ["› " <> root <> "/Alpha/", "  " <> root <> "/Beta/"]
    {:edit, last} = WorkspaceForm.key(form, %Key{code: "up"})
    assert suggestion_list(last).selected == 1
    {:edit, edited} = WorkspaceForm.key(chosen, %Key{code: "A"})
    assert suggestion_list(edited).selected == nil
    {:edit, completed} = WorkspaceForm.key(edited, %Key{code: "tab"})
    assert suggestion_list(completed).selected == nil
    assert WorkspaceForm.path(completed) == root <> "/Alpha/"
  end

  test "remote refresh does not silently select a replacement for a vanished choice" do
    form = WorkspaceForm.new("/remote", "remote", [], complete: nil)
    form = WorkspaceForm.paste(form, "/remote/")
    form = WorkspaceForm.suggest(form, {:ok, ["/remote/Alpha/", "/remote/Beta/"]})
    assert suggestion_list(form).selected == nil
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "down"})
    form = WorkspaceForm.suggest(form, {:ok, ["/remote/Beta/"]})
    assert suggestion_list(form).selected == nil
    assert {:submit, "/remote/"} = WorkspaceForm.key(form, %Key{code: "enter"})
  end

  defp suggestion_list(form) do
    {list, _} =
      Enum.find(WorkspaceForm.widgets(form, %{width: 100, height: 30}), fn
        {%ExRatatui.Widgets.List{}, _} -> true
        _ -> false
      end)

    list
  end

  test "typed capitals and shifted symbols preserve their case and complete a matching folder" do
    root = temporary_folders(["Project_É!", "project_lowercase"])
    form = WorkspaceForm.new(root)

    form =
      Enum.reduce(
        [
          {"P", ["shift"]},
          {"r", []},
          {"o", []},
          {"j", []},
          {"e", []},
          {"c", []},
          {"t", []},
          {"_", ["shift"]},
          {"É", ["shift"]}
        ],
        form,
        fn {code, modifiers}, form ->
          {:edit, next} =
            WorkspaceForm.key(form, %Key{code: code, kind: "press", modifiers: modifiers})

          next
        end
      )

    assert WorkspaceForm.path(form) == "Project_É"
    assert form.suggestions == [root <> "/Project_É!/"]
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(form) == root <> "/Project_É!/"
    assert {:submit, _} = WorkspaceForm.key(form, %Key{code: "enter"})
  end

  test "Shift inserts the terminal's actual characters while command modifiers remain shortcuts" do
    form = WorkspaceForm.new("/remote", "remote", [], complete: nil)

    for code <- ["A", "_", "~", "!", "É"] do
      {:edit, _} = WorkspaceForm.key(form, %Key{code: code, modifiers: ["shift"]})
    end

    {:edit, form} = WorkspaceForm.key(form, %Key{code: "Z", modifiers: []})
    assert WorkspaceForm.path(form) == "A_~!ÉZ"

    for modifiers <- [["ctrl"], ["alt"], ["super"], ["ctrl", "shift"]] do
      {:edit, _} = WorkspaceForm.key(form, %Key{code: "X", modifiers: modifiers})
      assert WorkspaceForm.path(form) == "A_~!ÉZ"
    end

    {:edit, form} = WorkspaceForm.key(form, %Key{code: "u", modifiers: ["ctrl"]})
    assert WorkspaceForm.path(form) == ""
  end

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
    {:edit, first} = WorkspaceForm.key(form, %Key{code: "down"})
    assert first.suggestion_index == 0
    {:edit, chosen} = WorkspaceForm.key(first, %Key{code: "down"})
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
    form = WorkspaceForm.suggest(form, {:ok, ["/remote/probe/", "/remote/project/"]})
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "up"})
    form = WorkspaceForm.suggest(form, {:ok, ["/remote/project/", "/remote/probe/"]})
    {:edit, completed} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(completed) == "/remote/project/"
  end

  test "Tab completes the typed prefix, never a saved working directory" do
    root = temporary_folders(["home/current/project", "home/another"])

    form =
      WorkspaceForm.new(root <> "/home/current/project", "host", [root <> "/home/current/project"])

    {:edit, empty} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(empty) == ""

    form = WorkspaceForm.paste(form, root <> "/hom")
    assert form.suggestions == [root <> "/home/"]
    {:edit, completed} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(completed) == root <> "/home/"
    assert completed.suggestions == [root <> "/home/another/", root <> "/home/current/"]
    {:edit, unchanged} = WorkspaceForm.key(completed, %Key{code: "tab"})
    assert WorkspaceForm.path(unchanged) == root <> "/home/"
  end

  test "ambiguous Tab extends only the common prefix and leaves all choices available" do
    root = temporary_folders(["project-one", "project-two", "猫屋", "猫咪"])
    form = WorkspaceForm.new(root) |> WorkspaceForm.paste("pro")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(form) == root <> "/project-"
    {:edit, same} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(same) == root <> "/project-"
    assert same.suggestions == [root <> "/project-one/", root <> "/project-two/"]
    {:edit, clicked} = WorkspaceForm.click(same, 4, 3)
    assert WorkspaceForm.path(clicked) == root <> "/project-one/"

    form = WorkspaceForm.new(root) |> WorkspaceForm.paste("猫")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(form) == root <> "/猫"
    assert String.valid?(WorkspaceForm.path(form))
    form = WorkspaceForm.new(root) |> WorkspaceForm.paste("new-folder")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(form) == "new-folder"
  end

  test "completion considers matches beyond the fifty displayed suggestions" do
    root = temporary_folders(Enum.map(1..55, &("aaa-" <> Integer.to_string(&1))) ++ ["az-last"])

    assert {:ok, %{folders: folders, completion: prefix}} =
             Alto.Harness.Folders.suggest("a", root)

    assert length(folders) == 50
    assert prefix == root <> "/a"
    form = WorkspaceForm.new(root) |> WorkspaceForm.paste("a")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert WorkspaceForm.path(form) == root <> "/a"
  end

  test "Tab waits for remote completion and then lists the completed folder's children" do
    form = WorkspaceForm.new("/home/current", "remote", ["/home/current"], complete: nil)
    form = WorkspaceForm.paste(form, "/hom")
    revision = form.revision
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    assert form.revision == revision
    assert WorkspaceForm.path(form) == "/hom"
    form = WorkspaceForm.suggest(form, {:ok, %{folders: ["/home/"], completion: "/home/"}})
    assert WorkspaceForm.path(form) == "/home/"
    assert form.revision != revision
    assert form.completion == :pending
    refute form.tab_pending?

    form =
      WorkspaceForm.suggest(
        form,
        {:ok, %{folders: ["/home/current/", "/home/other/"], completion: "/home/"}}
      )

    assert form.suggestions == ["/home/current/", "/home/other/"]

    form = WorkspaceForm.paste(form, "oth")
    {:edit, form} = WorkspaceForm.key(form, %Key{code: "tab"})
    form = WorkspaceForm.paste(form, "er/new")
    form = WorkspaceForm.suggest(form, {:ok, []})
    assert WorkspaceForm.path(form) == "/home/other/new"
    refute form.tab_pending?
  end

  defp temporary_folders(folders) do
    root = Path.join(System.tmp_dir!(), "alto-prefix-#{System.unique_integer([:positive])}")
    Enum.each(folders, &File.mkdir_p!(Path.join(root, &1)))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
