defmodule Alto.Contrib.Resident.CheckpointTest do
  use ExUnit.Case, async: false
  alias Alto.Contrib.Resident.{Config, Console, Service, Tasks}

  defmodule First do
    @behaviour Alto.Tool
    def name(_opts), do: :first
    def schema(_opts), do: %{description: "First", parameters: %{type: "object", properties: %{}}}
    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never

    def run(_, context, _opts) do
      File.write!(Path.join(context.cwd, "first"), "1", [:append])
      {:ok, "first"}
    end
  end

  defmodule Guarded do
    @behaviour Alto.Tool
    def name(_opts), do: :guarded

    def schema(_opts),
      do: %{description: "Guarded", parameters: %{type: "object", properties: %{}}}

    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :required

    def prepare(_, context, _opts) do
      File.write!(Path.join(context.cwd, "prepared"), "1", [:append])

      {:ok, %{value: File.read!(Path.join(context.cwd, "input"))},
       %{action: "append saved input"}}
    end

    def run(%{value: value}, context, _opts) do
      File.write!(Path.join(context.cwd, "approved"), value, [:append])
      {:ok, value}
    end
  end

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "zek-checkpoint-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "input"), "original")

    profile = fn steps ->
      Alto.Config.default(
        provider: nil,
        loop: Alto.rule_loop(steps: steps),
        tools: [First, Guarded],
        approval: :suspend,
        session_history: Map.get(context, :session_history, :completed),
        checkpoint_version: "test-v1"
      )
    end

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, max_attempts: 1, poll_ms: 10, run_timeout: 5_000],
        profiles: %{
          "guarded" => profile.(["first", "guarded"]),
          "four" => profile.(List.duplicate("guarded", 4)),
          "safe" => profile.(["first"]),
          "write" =>
            Alto.Config.default(
              provider: nil,
              loop: Alto.rule_loop(steps: ["write_file"]),
              tools: [Alto.Contrib.Tools.WriteFile],
              approval: :suspend,
              checkpoint_version: "test-write-v1"
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, name: name, config: config})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{name: name, config: config, dir: dir}
  end

  test "suspended work and its approval survive restart and full queues with the exact prepared value",
       %{name: name, config: config, dir: dir} do
    submit(name, "approval", "guarded")
    task = wait_for(name, "approval", "waiting_approval")
    assert task["approval"]["tool"] == "guarded"
    session = task["session_id"]
    assert is_binary(session)
    submit(name, "independent", "safe")
    wait_for(name, "independent", "completed")
    assert File.read!(Path.join(dir, "first")) == "11"
    stop_supervised!(Service)
    File.write!(Path.join(dir, "input"), "changed")
    config = %{config | scheduling: Keyword.put(config.scheduling, :max_pending, 1)}
    start_supervised!({Service, name: name, config: config})
    recovered = wait_for(name, "approval", "waiting_approval")
    assert recovered["approval"] == task["approval"]
    assert recovered["revision"] == task["revision"]

    assert {:error, :stale_revision} =
             Tasks.command(name, "decide", %{
               "id" => "approval",
               "revision" => task["revision"] - 1,
               "decision" => "approve"
             })

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "blocker",
               "profile" => "safe",
               "task" => "wait",
               "delay_ms" => 60_000
             })

    assert {:ok, %{"status" => "awaiting_admission"}} =
             Tasks.command(name, "decide", %{
               "id" => "approval",
               "revision" => task["revision"],
               "decision" => "approve"
             })

    assert {:error, _} =
             Tasks.command(name, "decide", %{
               "id" => "approval",
               "revision" => task["revision"],
               "decision" => "approve"
             })

    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    wait_for(name, "approval", "awaiting_admission")
    refute File.exists?(Path.join(dir, "approved"))
    assert {:ok, _} = Tasks.command(name, "cancel", %{"id" => "blocker"})

    done = wait_for(name, "approval", "completed")
    assert done["session_id"] == session
    assert File.read!(Path.join(dir, "approved")) == "original"
    assert File.read!(Path.join(dir, "prepared")) == "1"
    assert File.read!(Path.join(dir, "first")) == "11"
  end

  test "healthy approval continuations do not consume the ordinary retry allowance", %{
    name: name,
    dir: dir
  } do
    submit(name, "four", "four")

    Enum.each(1..4, fn _ ->
      task = wait_for(name, "four", "waiting_approval")

      assert {:ok, _} =
               Tasks.command(name, "decide", %{
                 "id" => "four",
                 "revision" => task["revision"],
                 "decision" => "approve"
               })
    end)

    wait_for(name, "four", "completed")
    assert File.read!(Path.join(dir, "approved")) == String.duplicate("original", 4)
  end

  test "the terminal recovers pending approval and sends a persisted denial", %{
    name: name,
    config: config,
    dir: dir
  } do
    submit(name, "denied", "guarded")
    wait_for(name, "denied", "waiting_approval")
    model = Console.perform(Console.new(socket: Config.socket_path(config)), :connect, self())
    model = Console.perform(model, {:select, "denied"}, self())
    assert model.detail =~ "Decision: guarded"
    Console.close(model)
    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    model = Console.perform(model, :connect, self())
    assert model.detail =~ "Decision: guarded"
    model = Console.perform(model, :deny, self())
    assert model.notice == "Decision sent"
    wait_for(name, "denied", "failed")
    refute File.exists?(Path.join(dir, "approved"))
    Console.close(model)
  end

  test "a real prepared write still rejects a file changed while approval was suspended", %{
    name: name,
    config: config,
    dir: dir
  } do
    path = Path.join(dir, "target.txt")
    File.write!(path, "before")

    Tasks.command(name, "submit", %{
      "id" => "write",
      "profile" => "write",
      "task" => JSON.encode!(%{path: "target.txt", content: "approved replacement"})
    })

    task = wait_for(name, "write", "waiting_approval")
    stop_supervised!(Service)
    File.write!(path, "user edit while suspended")
    start_supervised!({Service, name: name, config: config})

    assert {:ok, _} =
             Tasks.command(name, "decide", %{
               "id" => "write",
               "revision" => task["revision"],
               "decision" => "approve"
             })

    wait_for(name, "write", "failed")
    assert File.read!(path) == "user edit while suspended"
  end

  test "suspended cancellation survives restart without dispatch", %{
    name: name,
    config: config,
    dir: dir
  } do
    submit(name, "cancel", "guarded")
    wait_for(name, "cancel", "waiting_approval")
    assert {:ok, %{"status" => "cancelled"}} = Tasks.command(name, "cancel", %{"id" => "cancel"})
    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    wait_for(name, "cancel", "cancelled")
    refute File.exists?(Path.join(dir, "approved"))
  end

  test "restart completes cancellation even if the checkpoint claim was not acknowledged", %{
    name: name,
    config: config,
    dir: dir
  } do
    submit(name, "cancel-gap", "guarded")
    task = wait_for(name, "cancel-gap", "waiting_approval")
    worker = Service.component(name, {:worker, 1})
    :sys.suspend(worker)
    ledger = Service.component(name, :ledger)
    queue = Service.component(name, :queue)
    {:ok, recovered} = Alto.OperationLog.request(ledger, {:recovery, "cancel-gap"})

    {:ok, _} =
      Alto.Queue.request(
        queue,
        {:restore, "cancel-gap", recovered.recovery.generation_id, recovered.recovery.payload,
         recovery_revision: task["revision"]}
      )

    {:ok, [_]} = Alto.Queue.request(queue, {:claim, 1, "test-boundary", :infinity, :all})

    {:ok, _} =
      Alto.OperationLog.request(
        ledger,
        {:resume_checkpoint, "cancel-gap", task["revision"],
         %{
           "decision" => "cancel"
         }}
      )

    stop_supervised!(Service)
    start_supervised!({Service, name: name, config: config})
    wait_for(name, "cancel-gap", "cancelled")
    refute File.exists?(Path.join(dir, "approved"))
    assert File.read!(Path.join(dir, "first")) == "1"
  end

  defp submit(name, id, profile),
    do: Tasks.command(name, "submit", %{"id" => id, "profile" => profile, "task" => "{}"})

  defp wait_for(name, id, status),
    do: Alto.Test.ResidentTask.await(name, id, status, 150, 20)

  for decision <- ["approve", "deny"] do
    @tag decision: decision, session_history: :settled
    test "#{decision} rejects unsupported checkpoints without replaying completed effects", %{
      name: name,
      config: config,
      dir: dir,
      decision: decision
    } do
      submit(name, "unsupported", "guarded")
      task = wait_for(name, "unsupported", "waiting_approval")
      session_opts = [session_dir: Path.join(config.state_dir, "sessions")]
      {:ok, transcript} = Alto.Session.transcript(task["session_id"], session_opts)
      ledger = Service.component(name, :ledger)
      {:ok, current} = Alto.OperationLog.request(ledger, {:recovery, "unsupported"})
      packet = Map.put(current.checkpoint, "continuation_format", 0)

      {:ok, saved} =
        Alto.OperationLog.request(
          ledger,
          {:checkpoint_update, "unsupported", current.revision, packet}
        )

      stop_supervised!(Service)
      start_supervised!({Service, name: name, config: config})

      assert {:ok, _} =
               Tasks.command(name, "decide", %{
                 "id" => "unsupported",
                 "revision" => saved.revision,
                 "decision" => decision
               })

      failed = wait_for(name, "unsupported", "failed")
      assert failed["evidence"]["reason"] == ":checkpoint_mismatch"
      assert {:ok, ^transcript} = Alto.Session.transcript(task["session_id"], session_opts)

      assert {:ok, %{checkpoint: ^packet}} =
               Alto.OperationLog.request(ledger, {:recovery, "unsupported"})

      assert {:error, :stale_revision} =
               Tasks.command(name, "decide", %{
                 "id" => "unsupported",
                 "revision" => saved.revision,
                 "decision" => "approve"
               })

      stop_supervised!(Service)
      start_supervised!({Service, name: name, config: config})
      wait_for(name, "unsupported", "failed")
      assert File.read!(Path.join(dir, "first")) == "1"
      assert File.read!(Path.join(dir, "prepared")) == "1"
      refute File.exists?(Path.join(dir, "approved"))
    end
  end
end
