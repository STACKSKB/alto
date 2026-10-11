defmodule Alto.Contrib.Resident.CodingTeamApprovalTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Resident.Config

  defmodule Backend do
    @behaviour Alto.Contrib.Workspaces.Backend

    def snapshot(_source, _),
      do:
        {:ok,
         %{
           "base_commit" => String.duplicate("a", 40),
           "base_tree" => String.duplicate("b", 40)
         }}

    def checkout(_snapshot, path, _), do: File.mkdir_p(path)
    def diff(_, _, _), do: {:ok, "opaque patch"}

    def prepare_apply(_source, _patch, _digest, _opts),
      do: {:ok, %{"description" => "opaque backend approval"}}

    def verify_apply(_source, _manifest, _patch, _opts), do: :ok
    def apply(_source, _manifest, _patch, _opts), do: {:ok, %{"applied" => true}}
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto_resident-coding-approval-#{System.unique_integer([:positive])}"
      )

    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    name = make_ref()

    config =
      Config.new(
        workspace: source,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "local" =>
            Alto.Config.default(
              loop: Alto.loop(Alto.Contrib.Resident.CodingTeamApprovalTest.Backend)
            )
        },
        workspaces: [max_retained: 16, max_log_bytes: 100_000]
      )

    start_supervised!(Alto.Contrib.Resident.Workspaces.child(config, name))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, source: source, config: config, name: name}
  end

  defp manager(config, name),
    do: %{Alto.Contrib.Resident.Workspaces.manager(config.state_dir, name) | backend: Backend}

  defp req(tool),
    do: %{
      tool: tool,
      id: "op",
      call_id: "op",
      run_id: "team",
      arguments: %{},
      execution_mode: :exclusive,
      details: %{}
    }

  defp ctx(cwd, path),
    do: %{
      cwd: cwd,
      session_id: "team",
      agent_identity: %{root_run_id: "team", path: path}
    }

  test "approves owned worker file tools only while workspace is active", %{
    config: c,
    name: n,
    source: source
  } do
    m = manager(c, n)
    identity = %{root_run_id: "team", path: ["worker"]}
    {:ok, snapshot} = Alto.Contrib.Workspaces.prepare(m, source)
    {:ok, ready} = Alto.Contrib.Workspaces.create(m, snapshot, identity)
    parent = self()

    task =
      Task.async(fn ->
        Alto.Contrib.Workspaces.use(m, ready.id, ready.revision, fn ws ->
          send(parent, {:active, ws["cwd"]})

          assert :approve ==
                   Alto.Contrib.Resident.Approvals.CodingTeam.decide(
                     req("write_file"),
                     ctx(ws["cwd"], ["worker"]),
                     manager: m
                   )

          assert :approve ==
                   Alto.Contrib.Resident.Approvals.CodingTeam.decide(
                     req("edit_file"),
                     ctx(ws["cwd"], ["worker"]),
                     manager: m
                   )

          send(parent, :release)

          receive do
            :continue -> :ok
          end
        end)
      end)

    assert_receive {:active, cwd}, 2_000
    send(task.pid, :continue)
    assert_receive :release, 2_000
    Task.await(task)
    assert File.exists?(cwd)

    assert {:deny, :worker_workspace_not_owned} =
             Alto.Contrib.Resident.Approvals.CodingTeam.decide(
               req("write_file"),
               ctx(cwd, ["worker"]),
               manager: m
             )
  end

  test "suspends lead and denies other tools, wrong roots, cwd, and inactive workspaces", %{
    config: c,
    name: n,
    source: source
  } do
    m = manager(c, n)
    identity = %{root_run_id: "team", path: ["worker"]}
    {:ok, snapshot} = Alto.Contrib.Workspaces.prepare(m, source)
    {:ok, ready} = Alto.Contrib.Workspaces.create(m, snapshot, identity)
    {:ok, %{status: "ready", workspace: ws}} = Alto.Contrib.Workspaces.get(m, ready.id)
    policy = Alto.Contrib.Resident.Approvals.CodingTeam
    assert :suspend == policy.decide(req("write_file"), ctx(source, []), manager: m)

    assert {:deny, :worker_tool_not_permitted} =
             policy.decide(req("run_command"), ctx(ws["cwd"], ["worker"]), manager: m)

    assert {:deny, :worker_workspace_not_owned} =
             policy.decide(req("write_file"), ctx(ws["cwd"], ["peer"]), manager: m)

    assert {:deny, :worker_workspace_not_owned} =
             policy.decide(req("write_file"), ctx(source, ["worker"]), manager: m)

    assert {:deny, :worker_workspace_not_owned} =
             policy.decide(req("write_file"), ctx(ws["cwd"], ["worker"]), manager: m)
  end

  test "active ownership checks reject wrong root, peer and foreign manager", %{
    config: c,
    name: n,
    source: source
  } do
    m = manager(c, n)
    identity = %{root_run_id: "team", path: ["worker"]}
    {:ok, snapshot} = Alto.Contrib.Workspaces.prepare(m, source)
    {:ok, ready} = Alto.Contrib.Workspaces.create(m, snapshot, identity)

    assert {:ok, :ok, _} =
             Alto.Contrib.Workspaces.use(m, ready.id, ready.revision, fn ws ->
               valid = ctx(ws["cwd"], ["worker"])

               for context <- [
                     ctx(ws["cwd"], ["peer"]),
                     %{valid | agent_identity: %{root_run_id: "other", path: ["worker"]}},
                     %{valid | cwd: source}
                   ] do
                 assert {:deny, :worker_workspace_not_owned} =
                          Alto.Contrib.Resident.Approvals.CodingTeam.decide(
                            req("write_file"),
                            context,
                            manager: m
                          )
               end

               foreign = %{m | root: Path.join(c.state_dir, "other")}

               assert {:deny, :worker_workspace_not_owned} =
                        Alto.Contrib.Resident.Approvals.CodingTeam.decide(
                          req("write_file"),
                          valid,
                          manager: foreign
                        )

               :ok
             end)
  end

  test "manager source and digest authorize patches without backend-specific metadata", %{
    config: c,
    name: n,
    source: source
  } do
    m = manager(c, n)

    assert {:ok,
            %Alto.Contrib.Workspaces.Snapshot{source: ^source, metadata: metadata} = snapshot} =
             Alto.Contrib.Workspaces.prepare(m, source)

    refute Map.has_key?(metadata, "source")

    assert {:ok, ready} =
             Alto.Contrib.Workspaces.create(m, snapshot, %{root_run_id: "team", path: ["worker"]})

    assert {:ok, frozen} = Alto.Contrib.Workspaces.freeze(m, ready.id, ready.revision)

    assert {:ok, prepared, details} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.prepare(
               %{"workspace_id" => frozen.id, "revision" => frozen.revision},
               ctx(source, []),
               manager: m
             )

    assert details.source == source
    assert details.sha256 == frozen.workspace["patch_sha256"]
    assert prepared["patch_sha256"] == details.sha256
    refute Map.has_key?(prepared["integration"], "patch_sha256")
    assert details.files == []

    assert {:ok, %{status: "applied"}} =
             Alto.Contrib.Resident.Tools.ApplyWorkerPatch.run(prepared, ctx(source, []),
               manager: m
             )
  end
end
