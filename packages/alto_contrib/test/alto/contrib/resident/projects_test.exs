defmodule Alto.Contrib.Resident.ProjectsTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Resident.{Config, Console, Projects, Service, Tasks}

  defmodule WriteFolder do
    @behaviour Alto.Tool
    def name(_opts), do: :write_folder

    def schema(_opts),
      do: %{
        description: "Record the execution folder",
        parameters: %{type: "object", properties: %{}}
      }

    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never

    def run(_, context, _opts) do
      File.write!(Path.join(context.cwd, "ran.txt"), "run\n", [:append])
      {:ok, context.cwd}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "zek-projects-#{System.unique_integer([:positive])}")
    folder = Path.join(root, "second project")
    File.mkdir_p!(folder)

    config =
      Config.new(
        workspace: root,
        state_dir: Path.join(root, "state"),
        scheduling: [poll_ms: 10, workers: 1],
        profiles: %{
          "test" =>
            Alto.Config.default(
              provider: nil,
              loop: Alto.rule_loop(steps: ["write_folder"]),
              tools: [WriteFolder]
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(root) end)
    %{config: config, name: name, folder: folder, root: root}
  end

  test "console creates folders on the service host and opens the new workspace", ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    on_exit(fn -> Console.close(model) end)
    folder = Path.join(ctx.root, "New Parent/Project É!")
    opened = Console.perform(model, {:create_workspace, "New Parent/Project É!"}, self())
    assert File.dir?(folder)
    assert opened.workspace_root == folder
    assert opened.selected_id == nil
    assert opened.notice =~ "Workspace opened:"
    assert Enum.any?(opened.projects, &(&1["root"] == folder))

    duplicate = Console.perform(opened, {:create_workspace, folder}, self())
    assert duplicate.notice =~ "already exists"
    assert duplicate.workspace_id == opened.workspace_id
    assert duplicate.connection == "connected"

    File.write!(Path.join(ctx.root, "existing-file"), "keep")
    failed = Console.perform(opened, {:create_workspace, "existing-file"}, self())
    assert failed.notice =~ "file already exists"
    refute failed.notice =~ "%{"
    assert File.read!(Path.join(ctx.root, "existing-file")) == "keep"
    assert failed.workspace_id == opened.workspace_id

    invalid = Console.perform(opened, {:create_workspace, ""}, self())
    assert invalid.notice =~ "Enter a folder path"
    assert invalid.workspace_id == opened.workspace_id
  end

  test "console workspaces launch in their folder and follow-ups retain it", ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    assert model.workspace_base == ctx.root
    invalid = Console.perform(model, {:workspace, "missing-folder"}, self())
    assert invalid.notice =~ "does not exist"
    assert invalid.workspace_id == model.workspace_id
    assert invalid.connection == "connected"
    model = Console.perform(model, {:workspace, "second project"}, self())
    assert model.workspace_root == ctx.folder
    assert model.selected_id == nil
    id = model.workspace_id
    model = Console.perform(model, {:submit, "{}"}, self())
    assert model.notice == "Sent"
    task = completed(ctx.name, model.selected_id)
    assert task["cwd"] == ctx.folder
    assert task["workspace_id"] == id
    assert File.read!(Path.join(ctx.folder, "ran.txt")) == "run\n"
    refute File.exists?(Path.join(ctx.root, "ran.txt"))

    {:ok, %{project: other}} = Projects.open(ctx.config, ctx.root)

    assert {:error, :workspace_session_mismatch} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "wrong folder",
               "resume" => task["session_id"],
               "workspace_id" => other["id"]
             })

    assert {:ok, reply} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "{}",
               "resume" => task["session_id"]
             })

    followup = completed(ctx.name, reply["task_id"])
    assert followup["cwd"] == ctx.folder
    assert File.read!(Path.join(ctx.folder, "ran.txt")) == "run\nrun\n"
    refute File.exists?(Path.join(ctx.root, "ran.txt"))
    Console.close(model)
  end

  test "direct sessions restore their workspace on selection, refresh and new tasks", ctx do
    registry = Service.registry(ctx.name)

    assert {:ok, run} =
             Alto.Contrib.FrontEnd.Registry.request(
               registry,
               {:start_run, "test", "{}", [cwd: ctx.folder]}
             )

    session = Alto.Contrib.FrontEnd.Registry.request(registry, {:run_session, run})
    assert is_binary(session)

    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    on_exit(fn -> Console.close(model) end)
    assert model.workspace_root == ctx.root
    model = Console.perform(model, {:select, session}, self())
    assert model.connection == "connected"
    assert Enum.find(model.tasks, &(&1.id == session)).cwd == ctx.folder
    assert model.detail =~ ctx.folder

    model = Console.perform(model, :poll, self())
    direct = Enum.find(model.tasks, &(&1.id == session))
    assert direct.cwd == ctx.folder
    assert direct.workspace_id != nil

    fresh = Console.perform(model, :new, self())
    assert fresh.workspace_root == ctx.folder
    assert fresh.workspace_id == direct.workspace_id
    fresh = Console.perform(fresh, {:submit, "{}"}, self())
    assert fresh.notice == "Sent"
    assert completed(ctx.name, fresh.selected_id)["cwd"] == ctx.folder

    # Loading from a new connection also restores metadata from the session log.
    Console.close(fresh)

    reconnected =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    on_exit(fn -> Console.close(reconnected) end)
    reconnected = Console.perform(reconnected, {:select, session}, self())
    assert Enum.find(reconnected.tasks, &(&1.id == session)).cwd == ctx.folder
  end

  test "sessions without workspace metadata never reuse the console folder", ctx do
    assert {:ok, session} =
             Alto.Session.create("Unbound session", %{},
               session_dir: Path.join(ctx.config.state_dir, "sessions")
             )

    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    on_exit(fn -> Console.close(model) end)
    model = Console.perform(model, {:select, session}, self())
    assert model.detail =~ "Unknown"
    assert Console.perform(model, {:submit, "{}"}, self()).notice =~ "Workspace is unknown"
    model = Console.perform(model, :poll, self())
    model = Console.perform(model, :new, self())
    assert model.workspace_root == nil
    assert model.workspace_id == nil
    assert Console.perform(model, {:submit, "{}"}, self()).notice =~ "Open a workspace first"
  end

  test "selecting a saved workspace prepares a fresh task there without reordering folders",
       ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    default = Enum.find(model.projects, &(&1["root"] == ctx.root))
    model = Console.perform(model, {:workspace, "second project"}, self())
    model = Console.perform(model, {:submit, "{}"}, self())
    old_id = model.selected_id
    assert completed(ctx.name, old_id)["cwd"] == ctx.folder
    projects = model.projects
    model = Console.perform(model, {:select_workspace, default["id"]}, self())
    assert model.projects == projects
    assert model.selected_id == nil
    assert model.workspace_root == ctx.root
    assert model.workspace_id == default["id"]
    assert model.entries == []
    model = Console.perform(model, {:submit, "{}"}, self())
    assert model.selected_id != old_id
    assert completed(ctx.name, model.selected_id)["cwd"] == ctx.root
    Console.close(model)
  end

  test "closed workspaces retain tasks, stay closed on reconnect, and can be reopened", ctx do
    model =
      Console.perform(
        Console.new(socket: Config.socket_path(ctx.config), profile: "test"),
        :connect,
        self()
      )

    default_id = model.workspace_id
    model = Console.perform(model, {:workspace, "second project"}, self())
    other = model.workspace_id
    model = Console.perform(model, {:submit, "{}"}, self())
    task_id = model.selected_id
    completed(ctx.name, task_id)
    model = Console.perform(model, {:close_workspace, other}, self())
    assert model.workspace_id == default_id
    assert model.selected_id == nil
    assert Enum.find(model.projects, &(&1["id"] == other))["closed"]
    assert {:ok, bound} = Projects.bind(ctx.config, ctx.folder)
    assert bound["closed"]
    assert {:ok, folder} = Projects.root(ctx.config, other, ctx.root)
    assert folder == ctx.folder
    assert File.read!(Path.join(ctx.folder, "ran.txt")) == "run\n"
    assert completed(ctx.name, task_id)["cwd"] == ctx.folder

    model = Console.perform(model, :connect, self())
    assert Enum.find(model.projects, &(&1["id"] == other))["closed"]
    model = Console.perform(model, {:close_workspace, default_id}, self())
    assert model.workspace_id == nil
    assert model.workspace_root == nil
    rejected = Console.perform(model, {:submit, "{}"}, self())
    assert rejected.notice =~ "Open a workspace first"
    model = Console.perform(model, :connect, self())
    assert model.workspace_root == nil
    assert Enum.all?(model.projects, & &1["closed"])
    model = Console.perform(model, {:workspace, "second project"}, self())
    assert model.workspace_id == other
    refute Enum.find(model.projects, &(&1["id"] == other))["closed"]
    assert Enum.any?(model.tasks, &(&1.id == task_id))
    Console.close(model)
  end

  test "console completes directories on the service host without registering them", ctx do
    model = Console.perform(Console.new(socket: Config.socket_path(ctx.config)), :connect, self())

    assert {:ok, %{folders: folders, completion: completion}} =
             Console.complete_folders(model, "sec")

    assert folders == [ctx.folder <> "/"]
    assert completion == ctx.folder <> "/"
    assert {:error, _} = Console.complete_folders(model, "bad\npath")
    assert model.selected_id == nil
    assert model.workspace_root == ctx.root
    Console.close(model)
  end

  test "workspace registrations and queued folder choices survive restart", ctx do
    {:ok, %{project: project}} = Projects.open(ctx.config, ctx.folder)
    {:ok, %{project: same}} = Projects.open(ctx.config, ctx.folder)
    assert same["id"] == project["id"]

    assert {:ok, _} =
             Tasks.command(ctx.name, "submit", %{
               "id" => "delayed-folder",
               "profile" => "test",
               "task" => "later",
               "workspace_id" => project["id"],
               "delay_ms" => 60_000
             })

    stop_supervised!(Service)
    start_supervised!({Service, config: ctx.config, name: ctx.name})
    assert {:ok, folder} = Projects.root(ctx.config, project["id"], nil)
    assert folder == ctx.folder
    assert {:ok, %{"task" => task}} = Tasks.command(ctx.name, "get", %{"id" => "delayed-folder"})
    assert task["cwd"] == ctx.folder
    assert task["workspace_id"] == project["id"]
  end

  test "invalid folders and workspace identities are rejected before admission", ctx do
    for path <- ["", "  ", "a\nb", "a\tb", <<0>>, <<255>>, String.duplicate("a", 4097), nil] do
      assert {:error, :invalid_workspace_path} = Projects.open(ctx.config, path)
    end

    assert {:error, {:project_not_directory, _}} = Projects.open(ctx.config, "missing")

    assert {:error, :unknown_workspace} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "bad",
               "workspace_id" => "not-registered"
             })

    # A raw client-supplied cwd cannot bypass the registered workspace choice.
    assert {:ok, reply} =
             Tasks.command(ctx.name, "submit", %{
               "profile" => "test",
               "task" => "{}",
               "cwd" => ctx.folder
             })

    assert completed(ctx.name, reply["task_id"])["cwd"] == ctx.root
    assert File.exists?(Path.join(ctx.root, "ran.txt"))
    refute File.exists?(Path.join(ctx.folder, "ran.txt"))
  end

  defp completed(name, id, attempts \\ 150) do
    {:ok, %{"task" => task}} = Tasks.command(name, "get", %{"id" => id})

    cond do
      task["status"] == "completed" ->
        task

      attempts == 0 ->
        flunk("Task did not complete: #{inspect(task)}")

      true ->
        Process.sleep(20)
        completed(name, id, attempts - 1)
    end
  end
end
