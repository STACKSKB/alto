defmodule Alto.Contrib.Resident.ParentStoreFailureTest do
  use ExUnit.Case, async: false
  alias Alto.OperationLog
  alias Alto.Runner.Budget.Account
  alias Alto.Contrib.Resident.{Config, ParentRuns, Service, Tasks}

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _), do: {{:stop, task}, task, []}
    def handle_event(_, state, _), do: {:continue, state, []}
  end

  defmodule StoreProxy do
    use GenServer
    def start_link(target), do: GenServer.start_link(__MODULE__, target)
    def init(target), do: {:ok, %{target: target, fail: nil}}
    def handle_call({:fail, action}, _, state), do: {:reply, :ok, %{state | fail: action}}

    def handle_call(request, _, state) do
      action =
        case request do
          {:recovery, _} -> :recovery
          {:entries, :all} -> :keys
          other -> other
        end

      if action == state.fail,
        do: {:stop, :normal, state},
        else: {:reply, GenServer.call(state.target, request), state}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-parent-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = make_ref()

    proxy =
      start_supervised!(
        Supervisor.child_spec({StoreProxy, ParentRuns.ledger(name)}, restart: :temporary)
      )

    profile =
      Alto.Config.default(
        provider: nil,
        loop: Alto.loop(Echo),
        continuation_store: proxy,
        max_effects: 100,
        max_model_requests: 100
      )

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [max_effects: 3, max_model_requests: 2],
        profiles: %{"parent" => profile}
      )

    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{name: name, proxy: proxy, config: config}
  end

  test "an unavailable binding rejects submission without restarting Tasks", %{
    name: name,
    proxy: proxy
  } do
    pid = GenServer.whereis(Service.component(name, :tasks))
    :ok = GenServer.call(proxy, {:fail, :identity})

    assert {:error, {:parent_store_unavailable, _}} =
             Tasks.command(name, "submit", submission("offline"))

    assert GenServer.whereis(Service.component(name, :tasks)) == pid
    assert {:ok, %{"tasks" => []}} = Tasks.command(name, "list", %{})

    assert {:error, :not_found} =
             OperationLog.request(Service.component(name, :ledger), {:recovery, "offline"})
  end

  for failure <- [:keys] do
    test "store failure during #{failure} inspection preserves the task server", %{
      name: name,
      proxy: proxy,
      config: config
    } do
      assert {:ok, _} = Tasks.command(name, "submit", submission("parked"))
      {:ok, profile_options} = Config.resolve(config, "parent")
      {:ok, binding} = ParentRuns.store_binding(profile_options)
      pid = GenServer.whereis(Service.component(name, :tasks))
      :ok = GenServer.call(proxy, {:fail, unquote(failure)})

      assert %{state: "unavailable"} =
               ParentRuns.inspect_task(config, "parent", "parked", binding, name)

      assert GenServer.whereis(Service.component(name, :tasks)) == pid

      assert {:ok, %{"tasks" => tasks}} = Tasks.command(name, "list", %{})
      assert Enum.any?(tasks, &(&1["id"] == "parked"))
    end
  end

  test "parent account receives the already bounded profile options", %{
    name: name,
    config: config
  } do
    {:ok, opts} = Tasks.resolve(config, "scheduled/parent")
    {:ok, binding} = ParentRuns.store_binding(opts)
    payload = %{"id" => "bounded", "profile" => "parent", "parent_store" => binding}
    assert {:ok, extra} = ParentRuns.options(opts, name, payload, false)
    assert {:ok, %{packet: packet}} = Account.read(extra[:budget_account])
    assert packet["max_effects"] == 3
    assert packet["max_model_requests"] == 2
  end

  defp submission(id),
    do: %{"id" => id, "profile" => "parent", "task" => "work", "delay_ms" => 60_000}
end
