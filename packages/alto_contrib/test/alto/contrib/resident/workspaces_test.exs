defmodule Alto.Contrib.Resident.WorkspacesTest do
  use ExUnit.Case, async: true

  alias Alto.{Event}
  alias Alto.Contrib.Resident.{Config, Workspaces}

  defmodule WriteLoop do
    @behaviour Alto.Loop
    def init(%{content: content}, _spec),
      do:
        {:continue, %{},
         [
           {:invoke_tool,
            %{
              name: "write_file",
              arguments: %{"path" => "tracked.txt", "content" => content}
            }}
         ]}

    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: {{:stop, :done}, state, []}

    def handle_event(_event, state, _spec), do: {:continue, state, []}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto_resident-workspaces-#{System.unique_integer([:positive])}"
      )

    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "tracked.txt"), "base\n")
    git!(source, ["init", "-q"])
    git!(source, ["config", "user.email", "test@example.test"])
    git!(source, ["config", "user.name", "Alto.Contrib.Resident Test"])
    git!(source, ["add", "tracked.txt"])
    git!(source, ["commit", "-qm", "base"])
    name = make_ref()

    config =
      Config.new(
        workspace: source,
        state_dir: Path.join(dir, "state"),
        profiles: %{"local" => Alto.Config.default(loop: Alto.loop(WriteLoop))},
        workspaces: [max_retained: 16, max_log_bytes: 100_000]
      )

    start_supervised!(Workspaces.child(config, name))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, source: source, config: config, name: name}
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp manager(config, name), do: Workspaces.manager(config.state_dir, name)

  defp run_workspace(config, name, source, content, identity) do
    m = manager(config, name)
    {:ok, snapshot} = Alto.Contrib.Workspaces.prepare(m, source)
    {:ok, ready} = Alto.Contrib.Workspaces.create(m, snapshot, identity)

    {:ok, result, worked} =
      Alto.Contrib.Workspaces.use(m, ready.id, ready.revision, fn workspace ->
        Alto.run(%{content: content},
          loop: Alto.loop(WriteLoop),
          tools: [Alto.Contrib.Tools.WriteFile],
          approval: :approve,
          cwd: workspace["cwd"]
        )
      end)

    {:ok, frozen} = Alto.Contrib.Workspaces.freeze(m, worked.id, worked.revision)
    {:ok, %{result | workspace: frozen}}
  end

  test "creates, uses, freezes, and serves operator patch chunks", %{
    config: c,
    name: n,
    source: source
  } do
    assert {:ok, result} =
             run_workspace(c, n, source, String.duplicate("changed\n", 6_000), %{
               root_run_id: "r",
               path: ["a"]
             })

    ws = result.workspace
    assert ws.status == "frozen"
    commands = Workspaces.commands(c, n)
    assert {:ok, %{workspaces: listed}} = commands["workspaces.list"].(%{})
    assert Enum.any?(listed, &(&1.id == ws.id))
    assert {:ok, got} = commands["workspaces.get"].(%{"id" => ws.id})
    assert got.status == "frozen"
    assert got.workspace_id == ws.id
    assert {:ok, chunk} = commands["workspaces.patch"].(%{"id" => ws.id})
    assert is_integer(chunk.next_cursor)
    patch = collect_patch(commands, ws.id, chunk)
    assert :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower) == chunk.sha256
    assert patch =~ "+changed"
    assert byte_size(patch) == chunk.bytes

    assert {:error, :invalid_workspace_cursor} =
             commands["workspaces.patch"].(%{"id" => ws.id, "cursor" => byte_size(patch) + 1})

    refute File.read!(Path.join(source, "tracked.txt")) == "changed\n"
  end

  defp collect_patch(commands, id, chunk) do
    bytes = Base.decode64!(chunk.chunk)
    assert byte_size(bytes) <= 24_000

    if chunk.next_cursor do
      assert {:ok, next} =
               commands["workspaces.patch"].(%{"id" => id, "cursor" => chunk.next_cursor})

      assert next.sha256 == chunk.sha256
      bytes <> collect_patch(commands, id, next)
    else
      bytes
    end
  end

  test "stale discard is rejected and restart retains a readable patch", %{
    config: c,
    name: n,
    source: source
  } do
    assert {:ok, result} =
             run_workspace(c, n, source, "persisted\n", %{root_run_id: "r", path: ["b"]})

    ws = result.workspace
    commands = Workspaces.commands(c, n)

    assert {:error, :stale_workspace} =
             commands["workspaces.discard"].(%{
               "id" => ws.id,
               "revision" => ws.revision - 1,
               "note" => "stale"
             })

    stop_supervised!(Workspaces)
    start_supervised!(Workspaces.child(c, n))
    commands = Workspaces.commands(c, n)
    assert {:ok, chunk} = commands["workspaces.patch"].(%{"id" => ws.id})
    assert Base.decode64!(chunk.chunk) =~ "persisted"

    assert {:ok, %{status: "discarded"}} =
             commands["workspaces.discard"].(%{
               "id" => ws.id,
               "revision" => ws.revision,
               "note" => "reviewed"
             })
  end

  test "Team.loop preserves trusted workspace policy", %{config: c, name: n} do
    m = manager(c, n)
    spec = Alto.Contrib.Resident.Team.loop(workers: %{"local" => []}, workspaces: m)
    assert spec.subagents.workspaces == m
  end

  test "invalid workspace checkpoints fail closed without changing retained files", %{
    config: c,
    name: n,
    source: source
  } do
    m = manager(c, n)
    id = "ws-" <> String.duplicate("a", 64)
    root = Path.join(m.root, id)
    File.mkdir_p!(Path.join(root, "checkout"))
    patch_path = Path.join(root, "patch.diff")
    patch = "retained legacy patch\n"
    File.write!(patch_path, patch)
    File.chmod!(patch_path, 0o600)

    workspace = %{
      "id" => id,
      "owner" => %{"root_run_id" => "legacy", "path" => ["worker"]},
      "cwd" => Path.join(root, "checkout"),
      "snapshot" => %{"source" => source},
      "backend_fingerprint" => "previous-release",
      "patch_path" => patch_path,
      "patch_sha256" => Base.encode16(:crypto.hash(:sha256, patch), case: :lower),
      "patch_bytes" => byte_size(patch)
    }

    :ok = Alto.OperationLog.request(m.ledger, {:intent, id, "workspace", nil, workspace})
    :ok = Alto.OperationLog.request(m.ledger, {:attempt, id, "legacy-freeze"})

    :ok =
      Alto.OperationLog.request(
        m.ledger,
        {:checkpoint, id, "legacy-freeze",
         %{
           "version" => 1,
           "phase" => "frozen",
           "workspace" => workspace
         }}
      )

    {:ok, original} = Alto.OperationLog.request(m.ledger, {:recovery, id})

    packets = [
      original.checkpoint
      | for(
          invalid <- [
            workspace,
            Map.put(workspace, "source", nil),
            Map.put(workspace, "source", 42)
          ],
          do: %{
            version: 2,
            id: id,
            status: "frozen",
            workspace: invalid
          }
        )
    ]

    for packet <- packets do
      {:ok, current} = Alto.OperationLog.request(m.ledger, {:recovery, id})

      {:ok, before} =
        Alto.OperationLog.request(
          m.ledger,
          {:checkpoint_update, id, current.revision, packet}
        )

      commands = Workspaces.commands(c, n)

      assert {:error, :invalid_workspace_record} =
               commands["workspaces.get"].(%{"id" => id})

      assert {:ok, %{workspaces: []}} =
               commands["workspaces.list"].(%{})

      assert {:error, :invalid_workspace_record} = commands["workspaces.patch"].(%{"id" => id})

      assert {:error, :invalid_workspace_record} =
               commands["workspaces.discard"].(%{
                 "id" => id,
                 "revision" => before.revision,
                 "note" => "old format"
               })

      context = %{
        session_id: "legacy-review",
        cwd: source,
        agent_identity: %{root_run_id: "legacy", path: []}
      }

      assert {:error, :invalid_workspace_record} =
               Workspaces.for_descendant(context, id, manager: m)

      assert {:ok, ^before} = Alto.OperationLog.request(m.ledger, {:recovery, id})
      assert File.read!(patch_path) == patch
    end
  end
end
