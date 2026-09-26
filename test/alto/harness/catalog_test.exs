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
               %{"status" => "waiting", "conversation_id" => "sess-a"},
               opts
             )

    assert updated["conversation_id"] == "sess-a"
    assert {:ok, projects, tasks} = Catalog.navigation(opts)
    assert tasks[first["id"]] == [updated]
    assert tasks[second["id"]] == []
    assert MapSet.new(projects, & &1["id"]) == MapSet.new([first["id"], second["id"]])

    {:ok, older} = Catalog.create_task(first["id"], "Earlier task", opts)
    {:ok, archived} = Catalog.update_task(older["id"], %{"status" => "archived"}, opts)
    {:ok, catalog} = Catalog.read(opts)
    updated = Map.put(updated, "updated_at_ms", 20)
    archived = Map.put(archived, "updated_at_ms", 10)
    orphan = Map.merge(updated, %{"id" => "orphan", "project_id" => "missing"})
    first = Map.put(first, "last_opened_at_ms", 10)
    second = Map.put(second, "last_opened_at_ms", 20)

    File.write!(
      opts[:path],
      JSON.encode!(%{
        catalog
        | "projects" => [first, second],
          "tasks" => [archived, orphan, updated]
      })
    )

    assert {:ok, [^second, ^first], tasks} = Catalog.navigation(opts)
    assert tasks == %{first["id"] => [updated], second["id"] => []}

    assert {:ok, [^second, ^first], tasks} =
             Catalog.navigation(Keyword.put(opts, :archived, true))

    assert tasks == %{first["id"] => [updated, archived], second["id"] => []}
  end

  test "closing only changes navigation and reopening restores the same project and tasks", %{
    root: root,
    opts: opts
  } do
    File.write!(Path.join(root, "keep.txt"), "keep")
    {:ok, project} = Catalog.register_project(root, opts)
    {:ok, task} = Catalog.create_task(project["id"], "Still running", opts)
    assert {:ok, closed} = Catalog.close_project(project["id"], opts)
    assert closed["closed"]
    assert {:ok, [^closed], tasks} = Catalog.navigation(opts)
    assert tasks[project["id"]] == [task]
    assert File.read!(Path.join(root, "keep.txt")) == "keep"
    assert {:ok, touched} = Catalog.register_project(root, Keyword.put(opts, :reopen, false))
    assert touched["closed"]
    assert {:ok, reopened} = Catalog.register_project(root, opts)
    assert reopened["id"] == project["id"]
    refute reopened["closed"]
    assert {:ok, [^reopened], tasks} = Catalog.navigation(opts)
    assert tasks[reopened["id"]] == [task]
    assert {:error, {:unknown_project, "missing"}} = Catalog.close_project("missing", opts)
  end

  test "fails closed for unknown projects, tasks, and fields", %{opts: opts} do
    assert {:error, {:unknown_project, "missing"}} = Catalog.create_task("missing", "x", opts)
    assert {:error, {:unknown_task, "missing"}} = Catalog.update_task("missing", %{}, opts)

    assert {:error, {:invalid_task_fields, ["surprise"]}} =
             Catalog.update_task("missing", %{"surprise" => true}, opts)
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
    assert task["conversation_id"] == nil

    assert {:ok, updated} =
             Catalog.update_task(task["id"], %{"conversation_id" => "thr-123"}, opts)

    assert updated["conversation_id"] == "thr-123"

    assert {:error, {:invalid_task_backend, "../other"}} =
             Catalog.update_task(task["id"], %{"backend" => "../other"}, opts)

    assert {:error, :invalid_task_field_value} =
             Catalog.update_task(task["id"], %{"title" => nil}, opts)
  end

  test "rejects malformed records until explicitly replaced", %{root: root, opts: opts} do
    {:ok, project} = Catalog.register_project(root, opts)
    {:ok, _task} = Catalog.create_task(project["id"], "Keep me", opts)
    path = Keyword.fetch!(opts, :path)

    catalog = path |> File.read!() |> JSON.decode!()
    [task] = catalog["tasks"]
    malformed = Map.put(catalog, "tasks", [Map.delete(task, "conversation_id")])
    File.write!(path, JSON.encode!(malformed))

    assert {:error, {:catalog_invalid, ^path}} = Catalog.read(opts)
    assert {:error, {:catalog_invalid, ^path}} = Catalog.create_task(project["id"], "New", opts)
    assert :ok = Catalog.replace_invalid(opts)
    assert {:ok, %{"projects" => [], "tasks" => []}} = Catalog.read(opts)
  end
end
