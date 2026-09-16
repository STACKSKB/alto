defmodule Alto.TUI.WorkspaceFormTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.WorkspaceForm

  test "folder entry and the open action remain visible on narrow terminals" do
    for {width, height} <- [{120, 36}, {50, 16}] do
      form = WorkspaceForm.new("/projects") |> WorkspaceForm.paste("/projects/猫 folder")
      terminal = ExRatatui.init_test_terminal(width, height)

      assert :ok =
               ExRatatui.draw(
                 terminal,
                 WorkspaceForm.widgets(form, %{width: width, height: height})
               )

      screen = ExRatatui.get_buffer_content(terminal)
      assert screen =~ "New workspace"
      assert screen =~ "/projects/猫"
      assert screen =~ "folder"
      assert WorkspaceForm.path(form) == "/projects/猫 folder"
      assert screen =~ "[ Open workspace ]"
      assert screen =~ "[ Cancel ]"
      assert {:submit, "/projects/猫 folder"} = WorkspaceForm.click(form, 5, 3)
      assert :cancel = WorkspaceForm.click(form, 5, 23)
      recent = WorkspaceForm.new("/projects", "this computer", ["/projects/one", "/projects/two"])
      {:edit, recent} = WorkspaceForm.key(recent, %ExRatatui.Event.Key{code: "down"})
      assert WorkspaceForm.path(recent) == "/projects/one"
      {:edit, recent} = WorkspaceForm.key(recent, %ExRatatui.Event.Key{code: "down"})
      assert WorkspaceForm.path(recent) == "/projects/two"
    end
  end
end
