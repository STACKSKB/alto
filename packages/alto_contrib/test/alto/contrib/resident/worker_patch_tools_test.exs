defmodule Alto.Contrib.Resident.WorkerPatchToolsTest do
  use ExUnit.Case, async: true
  import Alto.TestSupport.Git, only: [git!: 2]

  alias Alto.Event
  alias Alto.Contrib.Resident.{Config, Workspaces}

  defmodule WriteLoop do
    @behaviour Alto.Loop
    def init(%{content: content}, _),
      do:
        {:continue, %{},
         [
           {:invoke_tool,
            %{
              name: "write_file",
              arguments: %{"path" => "tracked.txt", "content" => content}
            }}
         ]}

    def handle_event(%Event{type: :tool_completed}, s, _), do: {{:stop, :done}, s, []}
    def handle_event(_, s, _), do: {:continue, s, []}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto_resident-worker-patch-#{System.unique_integer([:positive])}"
      )

    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "tracked.txt"), "base\n")
    git!(source, ["init", "-q"])
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
    %{source: source, config: config, name: name}
  end

  defp manager(c, n), do: Workspaces.manager(c.state_dir, n)

  defp context(source, identity),
    do: %{cwd: source, agent_identity: identity, session_id: "review"}

  defp frozen(%{source: source, config: c, name: n}) do
    m = manager(c, n)
    {:ok, snapshot} = Alto.Contrib.Workspaces.prepare(m, source)
    identity = %{root_run_id: "team", path: ["worker"]}
    {:ok, ready} = Alto.Contrib.Workspaces.create(m, snapshot, identity)

    {:ok, %Alto.Runner.Result{status: :ok}, worked} =
      Alto.Contrib.Workspaces.use(m, ready.id, ready.revision, fn ws ->
        Alto.run(%{content: "worker change\n"},
          loop: Alto.loop(WriteLoop),
          tools: [Alto.Contrib.Tools.WriteFile],
          approval: :approve,
          cwd: ws["cwd"]
        )
      end)

    {:ok, frozen} = Alto.Contrib.Workspaces.freeze(m, worked.id, worked.revision)
    {m, frozen, identity}
  end

  test "reviews and applies a descendant worker patch with required approval", fixture do
    {m, ws, _identity} = frozen(fixture)
    ctx = context(fixture.source, %{root_run_id: "team", path: []})
    args = %{"workspace_id" => ws.id, "revision" => ws.revision}
    assert Alto.Contrib.Resident.Tools.ApplyWorkerPatch.approval([]) == :required

    assert {:ok, prepared, details} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(args, ctx, manager: m)

    assert details.workspace_id == ws.id
    assert details.source == fixture.source
    assert details.sha256 == prepared["patch_sha256"]
    assert details.sha256 == ws.workspace["patch_sha256"]

    assert {:ok, chunk} =
             Alto.Contrib.Resident.Tools.ReviewWorkerPatch.run(%{"workspace_id" => ws.id}, ctx,
               manager: m
             )

    assert Base.decode64!(chunk.chunk) =~ "worker change"

    assert {:ok, result} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.run(prepared, ctx, manager: m)

    assert result.status == "applied"
    assert File.read!(Path.join(fixture.source, "tracked.txt")) == "worker change\n"
  end

  test "prepared patch becomes stale when source changes", fixture do
    {m, ws, _} = frozen(fixture)
    ctx = context(fixture.source, %{root_run_id: "team", path: []})
    args = %{"workspace_id" => ws.id, "revision" => ws.revision}

    assert {:ok, prepared, _} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(args, ctx, manager: m)

    File.write!(Path.join(fixture.source, "tracked.txt"), "operator edit\n")

    assert {:error, :stale_patch_target} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.run(prepared, ctx, manager: m)
  end

  test "scope, cwd, and foreign prepared packets are denied", fixture do
    {m, ws, _} = frozen(fixture)
    args = %{"workspace_id" => ws.id, "revision" => ws.revision}
    good = context(fixture.source, %{root_run_id: "team", path: []})

    assert {:ok, prepared, _} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(args, good, manager: m)

    for bad <- [
          context(fixture.source, %{root_run_id: "other", path: []}),
          context(fixture.source, %{root_run_id: "team", path: ["worker"]}),
          context(fixture.source, %{root_run_id: "team", path: ["peer"]}),
          context(Path.join(fixture.source, "other"), %{root_run_id: "team", path: []})
        ] do
      assert {:error, _} =
               Alto.Contrib.Resident.Tools.ReviewWorkerPatch.run(%{"workspace_id" => ws.id}, bad,
                 manager: m
               )

      assert {:error, _} =
               Alto.Contrib.Resident.Tools.ApplyWorkerPatch.run(prepared, bad, manager: m)
    end
  end

  test "backend metadata cannot redirect the source used by scope and approval", fixture do
    {m, ws, _} = frozen(fixture)
    {:ok, entry} = Alto.OperationLog.request(m.ledger, {:recovery, ws.id})
    foreign = Path.join(fixture.source, "foreign")
    packet = put_in(entry.checkpoint, [:workspace, "snapshot", "source"], foreign)

    {:ok, changed} =
      Alto.OperationLog.request(m.ledger, {:checkpoint_update, ws.id, entry.revision, packet})

    args = %{"workspace_id" => ws.id, "revision" => changed.revision}

    assert {:ok, prepared, details} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(
               args,
               context(fixture.source, %{root_run_id: "team", path: []}),
               manager: m
             )

    assert details.source == fixture.source
    assert details.sha256 == prepared["patch_sha256"]

    assert {:error, :workspace_scope_mismatch} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(
               args,
               context(foreign, %{root_run_id: "team", path: []}),
               manager: m
             )

    assert File.read!(Path.join(fixture.source, "tracked.txt")) == "base\n"
  end
end
