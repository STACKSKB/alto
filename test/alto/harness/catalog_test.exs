defmodule Alto.Harness.CatalogTest do
  use ExUnit.Case, async: true

  alias Alto.Harness.Catalog

  setup do
    root = Path.join(System.tmp_dir!(), "alto-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "catalog.json")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: [path: path]}
  end

  test "registers projects and persists independently switchable tasks", %{root: root, opts: opts} do
    first_root = Path.join(root, "first")
    second_root = Path.join(root, "second")
    File.mkdir!(first_root)
    File.mkdir!(second_root)

    assert {:ok, first} = Catalog.register_project(first_root, Keyword.put(opts, :name, "First"))
    assert {:ok, second} = Catalog.register_project(second_root, opts)
    assert first["id"] != second["id"]

    assert {:ok, task} = Catalog.create_task(first["id"], "Implement adapter", opts)

    assert {:ok, updated} =
             Catalog.update_task(
               task["id"],
               %{status: "waiting", session_id: "sess-a", next_step: "Review the diff"},
               opts
             )

    assert updated["session_id"] == "sess-a"
    assert {:ok, [^updated]} = Catalog.tasks(first["id"], opts)
    assert {:ok, []} = Catalog.tasks(second["id"], opts)
    assert {:ok, projects} = Catalog.projects(opts)
    assert MapSet.new(projects, & &1["id"]) == MapSet.new([first["id"], second["id"]])
  end

  test "fails closed for unknown projects, tasks, and fields", %{opts: opts} do
    assert {:error, {:unknown_project, "missing"}} = Catalog.create_task("missing", "x", opts)
    assert {:error, {:unknown_task, "missing"}} = Catalog.update_task("missing", %{}, opts)

    assert {:error, {:invalid_task_fields, ["surprise"]}} =
             Catalog.update_task("missing", %{surprise: true}, opts)
  end

  test "persists backend ownership without treating Codex threads as Alto sessions", %{
    root: root,
    opts: opts
  } do
    assert {:ok, project} = Catalog.register_project(root, opts)

    assert {:ok, task} =
             Catalog.create_task(
               project["id"],
               "Codex task",
               Keyword.put(opts, :backend, "codex")
             )

    assert task["backend"] == "codex"
    assert task["session_id"] == nil

    assert {:ok, updated} =
             Catalog.update_task(task["id"], %{backend_thread_id: "thr-123"}, opts)

    assert updated["backend_thread_id"] == "thr-123"

    assert {:error, {:invalid_task_backend, "../other"}} =
             Catalog.update_task(task["id"], %{backend: "../other"}, opts)
  end
end
