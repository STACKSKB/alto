defmodule Alto.Runner.SerialWorkspaceTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, Event, OperationLog, Transition, Workspaces}

  defmodule ApproveAll do
    @behaviour Alto.Approval
    @impl true
    def decide(_request, _context, _opts), do: :approve
  end

  defmodule BlockingApproval do
    @behaviour Alto.Approval
    @impl true
    def decide(_request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), :workspace_approval_started)

      receive do
        :release -> :approve
      end
    end
  end

  defmodule BarrierApproval do
    @behaviour Alto.Approval
    @impl true
    def decide(_request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:workspace_barrier_entered, self()})

      receive do
        :release -> :approve
      end
    end
  end

  defmodule WriteLoop do
    @behaviour Alto.Loop

    @impl true
    def init(%{content: content}, _spec) do
      Transition.continue(%{}, [
        Effect.invoke_tool(%{
          id: "write",
          name: "write_file",
          arguments: %{"path" => "tracked.txt", "content" => content}
        })
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: Transition.stop(state, :written)

    @impl true
    def handle_event(%Event{type: :tool_failed, data: data}, state, _spec),
      do: Transition.stop(state, {:failed, data.error})

    @impl true
    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule BatchLoop do
    @behaviour Alto.Loop

    @impl true
    def init(%{agents: agents}, _spec),
      do: Transition.continue(%{}, [Effect.spawn_agents(%{agents: agents})])

    @impl true
    def handle_event(%Event{type: :subagents_completed, data: data}, state, _spec),
      do: Transition.stop(state, {:completed, data.results})

    @impl true
    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-runner-workspaces-#{System.unique_integer([:positive])}")

    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "tracked.txt"), "base\n")
    git!(source, ["init", "-q"])
    git!(source, ["config", "user.email", "alto@example.test"])
    git!(source, ["config", "user.name", "Alto Test"])
    git!(source, ["add", "tracked.txt"])
    git!(source, ["commit", "-qm", "base"])

    ledger_opts = [id: "runner-workspaces", name: nil, dir: Path.join(dir, "ledger"), max_ops: 32]
    ledger = start_supervised!({OperationLog, ledger_opts})
    manager = Workspaces.new(root: Path.join(dir, "workspaces"), ledger: ledger)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, source: source, manager: manager}
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp loop(manager) do
    Alto.loop(BatchLoop,
      subagents:
        Alto.Subagents.bounded(
          max_depth: 1,
          max_children: 2,
          max_concurrency: 2,
          workspaces: manager
        )
    )
  end

  defp run_opts(manager, dir, approval \\ ApproveAll) do
    [
      loop: loop(manager),
      cwd: Path.join(dir, "source"),
      tools: [Alto.Tools.WriteFile],
      approval: approval,
      session: :new,
      session_dir: Path.join(dir, "sessions"),
      approval_timeout: 15_000,
      tool_timeout: 15_000
    ]
  end

  test "concurrent children receive isolated workspaces and frozen patches", %{
    dir: dir,
    source: source,
    manager: manager
  } do
    agents = [
      %{id: "left", task: %{content: "left\n"}, loop: Alto.loop(WriteLoop)},
      %{id: "right", task: %{content: "right\n"}, loop: Alto.loop(WriteLoop)}
    ]

    test_pid = self()

    task =
      Task.async(fn ->
        Alto.run(
          %{agents: agents},
          run_opts(manager, dir, {BarrierApproval, test_pid: test_pid})
        )
      end)

    assert_receive {:workspace_barrier_entered, first_approval}, 15_000
    assert_receive {:workspace_barrier_entered, second_approval}, 15_000
    send(first_approval, :release)
    send(second_approval, :release)
    assert {:ok, result} = Task.await(task, 30_000)
    assert {:completed, results} = result.output
    assert Enum.all?(results, &(&1.status == :ok))

    [left, right] = Enum.sort_by(results, & &1.id)
    assert left.workspace.status == "frozen"
    assert right.workspace.status == "frozen"
    refute left.workspace.workspace["cwd"] == right.workspace.workspace["cwd"]
    assert File.read!(Path.join(source, "tracked.txt")) == "base\n"

    assert {:ok, left_patch} = Workspaces.patch(manager, left.workspace.id)
    assert {:ok, right_patch} = Workspaces.patch(manager, right.workspace.id)
    assert left_patch =~ "left"
    assert right_patch =~ "right"
    refute left_patch == right_patch
  end

  test "child assignment controls cwd; spawn maps cannot select a source cwd", %{
    dir: dir,
    source: source,
    manager: manager
  } do
    outside = Path.join(dir, "tracked.txt")
    agents = [%{id: "one", task: %{content: "child\n"}, cwd: dir, loop: Alto.loop(WriteLoop)}]
    assert {:ok, result} = Alto.run(%{agents: agents}, run_opts(manager, dir))
    assert {:completed, [%{status: :ok, workspace: workspace}]} = result.output
    assert File.read!(Path.join(source, "tracked.txt")) == "base\n"
    refute File.exists?(outside)
    assert workspace.workspace["cwd"] =~ Path.join(manager.root, workspace.id)
    refute workspace.workspace["cwd"] == dir
  end

  test "dirty source is rejected before any child launches", %{
    dir: dir,
    source: source,
    manager: manager
  } do
    File.write!(Path.join(source, "tracked.txt"), "dirty\n")

    assert {:error, {:invalid_spawn_agents, :source_dirty}, _result} =
             Alto.run(
               %{agents: [%{id: "never", task: %{content: "x\n"}, loop: Alto.loop(WriteLoop)}]},
               run_opts(manager, dir)
             )

    assert File.read!(Path.join(source, "tracked.txt")) == "dirty\n"
    assert Path.wildcard(Path.join(manager.root, "ws-*/checkout")) == []
  end

  test "parent cancellation retains an interrupted child workspace for review", %{
    dir: dir,
    manager: manager
  } do
    agents = [%{id: "blocked", task: %{content: "never-written\n"}, loop: Alto.loop(WriteLoop)}]

    {:ok, handle} =
      Alto.start(%{agents: agents}, run_opts(manager, dir, {BlockingApproval, test_pid: self()}))

    assert_receive :workspace_approval_started, 15_000
    assert :ok = Alto.cancel(handle, :operator_stop)
    assert {:error, {:cancelled, :operator_stop}, _result} = Alto.await(handle, 10_000)

    [checkout] = Path.wildcard(Path.join(manager.root, "ws-*/checkout"))
    id = checkout |> Path.dirname() |> Path.basename()

    assert {:ok, %{status: status, revision: revision, workspace: workspace}} =
             Workspaces.get(manager, id)

    assert status in ["in_progress", "worked", "frozen"]
    assert workspace["cwd"] == checkout
    assert File.read!(Path.join(checkout, "tracked.txt")) == "base\n"

    assert {:ok, %{status: "discarded"}} =
             Workspaces.discard(manager, id, revision, "cancelled worker reviewed")
  end
end
