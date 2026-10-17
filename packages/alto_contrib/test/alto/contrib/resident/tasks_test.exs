defmodule Alto.Contrib.Resident.TasksTest do
  use ExUnit.Case, async: false
  alias Alto.{OperationLog, Queue}
  alias Alto.Contrib.Socket.Client
  alias Alto.Contrib.Resident.{Config, Service, Tasks}

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _), do: {{:stop, task}, task, []}
    def handle_event(_, state, _), do: {:continue, state, []}
  end

  defmodule Failure do
    @behaviour Alto.Loop
    def init("limit", _), do: {{:error, {:model_request_limit, 2}}, nil, []}
    def init(task, _), do: {{:error, task}, nil, []}
    def handle_event(_, state, _), do: {:continue, state, []}
  end

  defmodule Controlled do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      task = List.last(request.messages)["content"]
      send(Keyword.fetch!(opts, :owner), {:started, task, self()})

      receive do
        :finish -> {:ok, %{message: "finished", tool_calls: []}}
      end
    end
  end

  defmodule ExternalEffect do
    @behaviour Alto.Tool
    def name(_opts), do: :append_once

    def schema(_opts),
      do: %{description: "Test commit boundary", parameters: %{type: "object", properties: %{}}}

    def execution_mode(_opts), do: :exclusive
    def approval(_opts), do: :never

    def run(_, context, _opts) do
      File.write!(Path.join(context.cwd, "committed-effect"), "1", [:append])

      receive do
        :finish -> {:ok, "done"}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-tasks-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    File.mkdir_p!(dir)

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [poll_ms: 10, workers: 2, run_timeout: 5_000],
        profiles: %{
          "echo" => Alto.Config.default(provider: nil, loop: Alto.loop(Echo)),
          "failure" => Alto.Config.default(provider: nil, loop: Alto.loop(Failure)),
          "effect" =>
            Alto.Config.default(
              provider: nil,
              loop: Alto.rule_loop(steps: ["append_once"]),
              tools: [ExternalEffect]
            ),
          "controlled" =>
            Alto.Config.default(
              provider: {Controlled, owner: self()},
              loop: Alto.chat_loop(),
              tools: []
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{name: name, config: config}
  end

  test "bounded failure explanations survive service restart", %{name: name, config: config} do
    for {id, task} <- [{"limit", "limit"}, {"large", String.duplicate("🦀", 3_000)}] do
      assert {:ok, _} =
               Tasks.command(name, "submit", %{"id" => id, "profile" => "failure", "task" => task})

      failed = eventually(name, id, "failed")
      reason = failed["evidence"]["reason"]
      assert is_binary(reason) and String.valid?(reason)
      assert String.length(reason) <= 2_048
    end

    before = eventually(name, "limit", "failed")
    assert before["evidence"]["reason"] == "{:model_request_limit, 2}"
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    assert eventually(name, "limit", "failed")["evidence"]["reason"] ==
             before["evidence"]["reason"]
  end

  test "delayed tasks persist through restart and duplicate admission never replaces work", %{
    name: name,
    config: config
  } do
    assert {:ok, %{"task_id" => "due"}} =
             Tasks.command(name, "submit", %{
               "id" => "due",
               "profile" => "controlled",
               "task" => "original",
               "delay_ms" => 300
             })

    assert {:ok, %{"duplicate" => true}} =
             Tasks.command(name, "submit", %{
               "id" => "due",
               "profile" => "controlled",
               "task" => "replacement"
             })

    refute_receive {:started, _, _}, 30
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    assert_receive {:started, "original", provider}, 2_000
    send(provider, :finish)
    task = eventually(name, "due", "completed")
    assert is_binary(task["session_id"])
    assert task["evidence"]["status"] == "completed"
    refute_receive {:started, "replacement", _}
  end

  test "two bounded workers leave further work queued until a slot is free", %{name: name} do
    for id <- ~w(one two three) do
      assert {:ok, _} =
               Tasks.command(name, "submit", %{
                 "id" => id,
                 "profile" => "controlled",
                 "task" => id
               })
    end

    assert_receive {:started, "one", one}, 2_000
    assert_receive {:started, "two", two}, 2_000
    refute_receive {:started, "three", _}, 50
    send(one, :finish)
    assert_receive {:started, "three", three}, 2_000
    send(two, :finish)
    send(three, :finish)
    for id <- ~w(one two three), do: eventually(name, id, "completed")
  end

  test "restart parks an interrupted dispatch instead of repeating it", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{
      "id" => "uncertain",
      "profile" => "controlled",
      "task" => "once"
    })

    assert_receive {:started, "once", _}, 2_000
    eventually(name, "uncertain", "running")
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    task = eventually(name, "uncertain", "requires_operator")
    refute_receive {:started, "once", _}, 100

    assert {:error, :stale_revision} =
             Tasks.command(name, "reconcile", %{
               "id" => "uncertain",
               "revision" => task["revision"] - 1,
               "resolution" => "retry",
               "note" => "stale test grant"
             })

    assert {:ok, _} =
             Tasks.command(name, "reconcile", %{
               "id" => "uncertain",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "safe controlled test"
             })

    assert_receive {:started, "once", provider}, 2_000
    send(provider, :finish)
    eventually(name, "uncertain", "completed")
    refute_receive {:started, "once", _}, 50
  end

  test "pending cancellation is durable and active cancellation uses the run handle", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{
      "id" => "later",
      "profile" => "controlled",
      "task" => "later",
      "delay_ms" => 1_000
    })

    assert {:ok, %{"status" => "cancelled"}} = Tasks.command(name, "cancel", %{"id" => "later"})
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "later", "cancelled")

    Tasks.command(name, "submit", %{
      "id" => "active",
      "profile" => "controlled",
      "task" => "active"
    })

    assert_receive {:started, "active", _}, 2_000
    eventually(name, "active", "running")

    assert {:ok, %{"status" => "cancellation_requested"}} =
             Tasks.command(name, "cancel", %{"id" => "active"})

    eventually(name, "active", "cancelled")
  end

  test "socket application commands admit and inspect durable tasks", %{
    config: config,
    name: name
  } do
    {:ok, client} = Client.connect(Config.socket_path(config))
    on_exit(fn -> Client.close(client) end)

    assert {:ok, %{"task_id" => "socket"}} =
             Client.request(client, %{
               type: "command",
               name: "tasks.submit",
               payload: %{"id" => "socket", "profile" => "echo", "task" => "hello"}
             })

    eventually(name, "socket", "completed")

    assert {:ok, %{"tasks" => [task]}} =
             Client.request(client, %{type: "command", name: "tasks.list", payload: %{}})

    assert task["id"] == "socket"
  end

  test "an effect committed before a crash is never silently repeated", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{"id" => "effect", "profile" => "effect", "task" => "{}"})
    path = Path.join(config.workspace, "committed-effect")
    await_file(path)
    assert File.read!(path) == "1"
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "effect", "requires_operator")
    Tasks.command(name, "submit", %{"id" => "independent", "profile" => "echo", "task" => "safe"})
    eventually(name, "independent", "completed")
    assert File.read!(path) == "1"
  end

  test "each explicit retry grant permits one later attempt", %{name: name, config: config} do
    Tasks.command(name, "submit", %{
      "id" => "retry-twice",
      "profile" => "controlled",
      "task" => "retry-me"
    })

    for attempt <- 1..2 do
      assert_receive {:started, "retry-me", _}, 2_000
      eventually(name, "retry-twice", "running")
      stop_supervised!(Service)
      start_supervised!({Service, config: config, name: name})
      task = eventually(name, "retry-twice", "requires_operator")

      assert {:ok, _} =
               Tasks.command(name, "reconcile", %{
                 "id" => "retry-twice",
                 "revision" => task["revision"],
                 "resolution" => "retry",
                 "note" => "test grant #{attempt}"
               })
    end

    assert_receive {:started, "retry-me", worker}, 2_000
    send(worker, :finish)
    eventually(name, "retry-twice", "completed")
  end

  test "restart completes a retry grant whose queue restore was interrupted", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{
      "id" => "grant-gap",
      "profile" => "controlled",
      "task" => "grant"
    })

    assert_receive {:started, "grant", _}, 2_000
    eventually(name, "grant-gap", "running")
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    task = eventually(name, "grant-gap", "requires_operator")
    ledger = Service.component(name, :ledger)

    assert {:ok, _} =
             OperationLog.request(
               ledger,
               {:reconcile, "grant-gap", task["revision"], :retry_permitted,
                %{note: "test grant interrupted before admission"}}
             )

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    assert_receive {:started, "grant", worker}, 2_000
    send(worker, :finish)
    eventually(name, "grant-gap", "completed")
  end

  test "restart finishes cancellation interrupted after the pending record was removed", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{
      "id" => "cancel-gap",
      "profile" => "controlled",
      "task" => "must not run",
      "delay_ms" => 10_000
    })

    queue = Service.component(name, :queue)
    ledger = Service.component(name, :ledger)
    {:ok, record} = Queue.request(queue, {:lookup, "cancel-gap"})

    assert :ok =
             OperationLog.request(
               ledger,
               {:intent, "cancel-gap", "alto_resident_task", "cancel-gap",
                %{key: "cancel-gap", generation_id: record.generation_id, payload: record.payload}}
             )

    assert :ok = Queue.request(queue, {:cancel_pending, "cancel-gap"})
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "cancel-gap", "cancelled")
    refute_receive {:started, "must not run", _}, 100
  end

  test "an approved retry waits for queue capacity across restart", %{name: name, config: config} do
    stop_supervised!(Service)
    config = %{config | scheduling: Keyword.put(config.scheduling, :max_pending, 1)}
    start_supervised!({Service, config: config, name: name})

    Tasks.command(name, "submit", %{
      "id" => "capacity-retry",
      "profile" => "controlled",
      "task" => "retry when free"
    })

    assert_receive {:started, "retry when free", _}, 2_000
    eventually(name, "capacity-retry", "running")
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    task = eventually(name, "capacity-retry", "requires_operator")

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "blocker",
               "profile" => "controlled",
               "task" => "blocker",
               "delay_ms" => 60_000
             })

    assert {:ok, %{"status" => "awaiting_admission"}} =
             Tasks.command(name, "reconcile", %{
               "id" => "capacity-retry",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "explicit grant despite full queue"
             })

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "capacity-retry", "awaiting_admission")
    refute_receive {:started, "retry when free", _}, 100
    assert {:ok, _} = Tasks.command(name, "cancel", %{"id" => "blocker"})
    assert_receive {:started, "retry when free", worker}, 2_000
    send(worker, :finish)
    eventually(name, "capacity-retry", "completed")
    refute_receive {:started, "retry when free", _}, 100
  end

  test "an approved retry waiting for capacity can be durably cancelled", %{
    name: name,
    config: config
  } do
    stop_supervised!(Service)
    config = %{config | scheduling: Keyword.put(config.scheduling, :max_pending, 1)}
    start_supervised!({Service, config: config, name: name})

    Tasks.command(name, "submit", %{
      "id" => "cancel-retry",
      "profile" => "controlled",
      "task" => "cancel retry"
    })

    assert_receive {:started, "cancel retry", _}, 2_000
    eventually(name, "cancel-retry", "running")
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    task = eventually(name, "cancel-retry", "requires_operator")

    Tasks.command(name, "submit", %{
      "id" => "blocker",
      "profile" => "controlled",
      "task" => "blocker",
      "delay_ms" => 60_000
    })

    assert {:ok, _} =
             Tasks.command(name, "reconcile", %{
               "id" => "cancel-retry",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "test grant"
             })

    assert {:ok, %{"status" => "cancelled"}} =
             Tasks.command(name, "cancel", %{"id" => "cancel-retry"})

    Tasks.command(name, "cancel", %{"id" => "blocker"})
    refute_receive {:started, "cancel retry", _}, 300
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "cancel-retry", "cancelled")
    refute_receive {:started, "cancel retry", _}, 300
  end

  test "restart removes queued work after a durable cancellation decision", %{
    name: name,
    config: config
  } do
    Tasks.command(name, "submit", %{
      "id" => "decision-gap",
      "profile" => "controlled",
      "task" => "never dispatch",
      "delay_ms" => 60_000
    })

    queue = Service.component(name, :queue)
    ledger = Service.component(name, :ledger)
    {:ok, record} = Queue.request(queue, {:lookup, "decision-gap"})

    :ok =
      OperationLog.request(
        ledger,
        {:intent, "decision-gap", "alto_resident_task", "decision-gap",
         %{
           key: "decision-gap",
           generation_id: record.generation_id,
           payload: record.payload
         }}
      )

    :ok =
      OperationLog.request(ledger, {:reject_intended, "decision-gap", 1, %{status: "cancelled"}})

    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    eventually(name, "decision-gap", "cancelled")
    assert {:error, :not_found} = Queue.request(queue, {:lookup, "decision-gap"})
    refute_receive {:started, "never dispatch", _}, 100
  end

  defp await_file(path, attempts \\ 100)
  defp await_file(_path, 0), do: flunk("effect did not commit")

  defp await_file(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await_file(path, attempts - 1)
        )
  end

  defp eventually(name, id, status),
    do: Alto.Test.ResidentTask.await(name, id, status, 150, 20)
end
