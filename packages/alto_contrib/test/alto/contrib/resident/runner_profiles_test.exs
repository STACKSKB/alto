defmodule Alto.Contrib.Resident.RunnerProfilesTest do
  use ExUnit.Case, async: false

  alias Alto.Contrib.FrontEnd.Registry, as: Runs
  alias Alto.Contrib.Resident.{Config, Service, Tasks}

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _), do: {{:stop, task}, task, []}
    def handle_event(_, state, _), do: {:continue, state, []}
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_started, self()})

      receive do
        :finish -> {:ok, %{message: "finished", tool_calls: []}}
      end
    end
  end

  defmodule ProbeRunner do
    @behaviour Alto.Runner
    defmodule Handle do
      @enforce_keys [:host]
      defstruct [:host]
    end

    def run(task, opts) do
      if pid = Process.whereis(:alto_resident_runner_probe) do
        send(pid, {:runner_seen, self(), Keyword.get(opts, :runner_options, [])})
      end

      Alto.Runner.Serial.run(task, opts)
    end

    def start(task, opts) do
      {:ok, host} =
        Alto.Runner.TaskHost.start(
          fn ref -> run(task, Keyword.put(opts, :cancel_ref, ref)) end,
          opts
        )

      {:ok, %Handle{host: host}}
    end

    def await(%Handle{host: host}, timeout), do: Alto.Runner.TaskHost.await(host, timeout)
    def cancel(%Handle{host: host}, reason), do: Alto.Runner.TaskHost.cancel(host, reason)
    def terminate(%Handle{host: host}, reason), do: Alto.Runner.TaskHost.terminate(host, reason)
    def subscribe(%Handle{host: host}, pid), do: Alto.Runner.TaskHost.subscribe(host, pid)
  end

  test "trusted runner and runner_options survive both config resolvers" do
    options = [
      runner: ProbeRunner,
      runner_options: [mode: :automatic],
      run_timeout: 2_000,
      max_model_requests: 99,
      max_effects: 99
    ]

    config = Config.new(workspace: File.cwd!(), profiles: %{"p" => Alto.Config.default(options)})
    assert {:ok, resolved} = Config.resolve(config, "p")
    assert Keyword.take(resolved, Keyword.keys(options)) == options
    assert {:ok, resolved} = Tasks.resolve(config, "p")
    assert Keyword.take(resolved, Keyword.keys(options)) == options

    capped =
      Config.new(
        workspace: File.cwd!(),
        scheduling: [run_timeout: 1_000, max_model_requests: 7, max_effects: 8],
        profiles: %{"p" => Alto.Config.default(options)}
      )

    assert {:ok, scheduled} = Tasks.resolve(capped, "scheduled/p")
    assert scheduled[:runner] == ProbeRunner
    assert scheduled[:runner_options] == [mode: :automatic]
    assert scheduled[:run_timeout] == 1_000
    assert scheduled[:max_model_requests] == 7
    assert scheduled[:max_effects] == 8
  end

  test "scheduled service executes and cancels through the configured custom runner" do
    dir = temp_dir("service")

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, poll_ms: 10, run_timeout: 2_000],
        profiles: %{
          "echo" =>
            Alto.Config.default(
              provider: nil,
              loop: Alto.loop(Echo),
              runner: ProbeRunner,
              runner_options: [mode: :automatic]
            ),
          "blocked" =>
            Alto.Config.default(
              provider: {BlockingProvider, test_pid: self()},
              loop: Alto.chat_loop(),
              runner: ProbeRunner,
              runner_options: [mode: :automatic]
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, _} =
             Tasks.command(name, "submit", %{"id" => "done", "profile" => "echo", "task" => "ok"})

    assert eventually(name, "done", "completed")

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "stop",
               "profile" => "blocked",
               "task" => "wait"
             })

    assert_receive {:provider_started, _provider}, 2_000
    running = eventually(name, "stop", "running")
    assert is_binary(running["run_id"])
    assert :ok = Runs.request(Service.registry(name), {:cancel, running["run_id"], :test_stop})
    assert eventually(name, "stop", "cancelled")
  end

  test "custom runner is used for parent and child; runner options stay on the root profile" do
    dir = temp_dir("custom")
    Process.register(self(), :alto_resident_runner_probe)
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [mode: :automatic]

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "custom" =>
            Alto.Config.default(
              runner: ProbeRunner,
              runner_options: opts,
              loop:
                Alto.loop(Alto.Contrib.Resident.RunnerProfilesTest.SpawnOnceLoop,
                  subagents: Alto.Subagents.bounded(max_depth: 1)
                ),
              provider:
                {Alto.Contrib.Resident.RunnerProfilesTest.AnswerProvider, answer: "parent"}
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    registry = Service.registry(name)
    assert {:ok, run} = Runs.request(registry, {:start_run, "custom", "parent task", []})
    assert :ok = Runs.request(registry, {:attach, self(), run, 1, []})
    assert eventually_run(registry, run)

    assert {:ok,
            %Alto.Runner.Result{
              output: {:completed, [%{id: "child", status: :ok, output: "parent"}]}
            }} = Runs.request(registry, {:run_result, run})

    assert_receive {:runner_seen, _parent, ^opts}, 1_000
    assert_receive {:runner_seen, _child, []}, 1_000
    refute_receive {:runner_seen, _, _}, 100
  end

  defmodule SpawnOnceLoop do
    @behaviour Alto.Loop
    def init(_task, _),
      do:
        {:continue, %{},
         [
           {:spawn_agents, %{agents: [%{id: "child", task: "child task"}]}}
         ]}

    def handle_event(%Alto.Event{type: :subagents_completed, data: %{results: results}}, _, _),
      do: {{:stop, {:completed, results}}, :done, []}

    def handle_event(%Alto.Event{type: :subagent_failed, data: data}, _, _),
      do: {{:stop, {:failed, data}}, :done, []}

    def handle_event(_, state, _), do: {:continue, state, []}
  end

  defmodule AnswerProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def stream(_request, _sink, opts), do: {:ok, %{message: opts[:answer], tool_calls: []}}
  end

  defp eventually_run(registry, run, tries \\ 200)
  defp eventually_run(_registry, _run, 0), do: flunk("run did not finish")

  defp eventually_run(registry, run, tries) do
    case Runs.request(registry, {:run_result, run}) do
      {:ok, _} ->
        :ok

      :running ->
        Process.sleep(10)
        eventually_run(registry, run, tries - 1)
    end
  end

  defp eventually(name, id, status),
    do: Alto.Test.ResidentTask.await(name, id, status, 200, 10)

  defp temp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "alto_resident-runner-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
