defmodule Alto.TUI.CatalogRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Alto.Harness.Catalog
  alias Alto.TUI.State

  test "an invalid catalog is replaced only after a warning and confirmation" do
    root = Path.join(System.tmp_dir!(), "alto-tui-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "harness.json")
    old = JSON.encode!(%{"version" => 2, "projects" => [%{"id" => "old"}], "tasks" => []})
    File.write!(path, old)
    config = Alto.Test.TUI.config()

    {:ok, input} = StringIO.open("no\n")
    {:ok, output} = StringIO.open("")

    assert {:error, {:catalog_overwrite_declined, ^path}} =
             Alto.TUI.prepare_catalog(config, path: path, input: input, output: output)

    assert File.read!(path) == old
    {_input, warning} = StringIO.contents(output)
    assert warning =~ "Warning: catalog #{path} is invalid"
    assert warning =~ "Overwrite it with an empty catalog?"

    {:ok, input} = StringIO.open("yes\n")
    {:ok, output} = StringIO.open("")
    assert :ok = Alto.TUI.prepare_catalog(config, path: path, input: input, output: output)
    assert {:ok, %{"projects" => [], "tasks" => []}} = Catalog.read(path: path)
    assert {:ok, _state} = State.new(config, project: root, path: path)

    current = File.read!(path)
    assert :ok = Catalog.replace_invalid(path: path)
    assert File.read!(path) == current
  end

  test "the Mix entry point warns and exits cleanly when overwrite is declined" do
    root = Path.join(System.tmp_dir!(), "alto-tui-entry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "harness.json")
    config = Path.join(root, "config.exs")
    invalid = ~s({"version":2,"projects":[],"tasks":[{"title":42}]})
    File.write!(catalog, invalid)
    File.write!(config, "Alto.Config.new()")

    warning =
      capture_io(:stderr, fn ->
        capture_io("no\n", fn ->
          assert :ok = Mix.Tasks.Alto.Tui.run(["--config", config, "--catalog", catalog])
        end)
      end)

    assert warning =~ "Warning: catalog #{catalog} is invalid"
    assert warning =~ "Overwrite it with an empty catalog?"
    assert File.read!(catalog) == invalid
  end

  test "malformed tasks in a current-version catalog reach the recovery prompt" do
    root = Path.join(System.tmp_dir!(), "alto-tui-shape-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "harness.json")

    File.write!(
      path,
      JSON.encode!(%{"version" => 2, "projects" => [], "tasks" => [%{"title" => 42}]})
    )

    assert {:error, {:catalog_invalid, ^path}} = Catalog.read(path: path)

    {:ok, input} = StringIO.open("yes\n")
    {:ok, output} = StringIO.open("")

    assert :ok =
             Alto.TUI.prepare_catalog(Alto.Test.TUI.config(),
               path: path,
               input: input,
               output: output
             )

    {_input, warning} = StringIO.contents(output)
    assert warning =~ "Warning: catalog #{path} is invalid"
    assert {:ok, %{"projects" => [], "tasks" => []}} = Catalog.read(path: path)
  end
end
