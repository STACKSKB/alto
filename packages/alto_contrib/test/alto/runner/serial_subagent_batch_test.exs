defmodule Alto.Runner.SerialSubagentBatchTest do
  use ExUnit.Case, async: true

  alias Alto.Event

  defmodule BatchLoop do
    @behaviour Alto.Loop

    @impl true
    def init(%{agents: agents}, _spec),
      do: {:continue, %{}, [{:spawn_agents, %{agents: agents}}]}

    @impl true
    def handle_event(%Event{type: :subagents_completed, data: data}, state, _spec),
      do: {{:stop, {:completed, data}}, state, []}

    @impl true
    def handle_event(_event, state, _spec), do: {:continue, state, []}
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:batch_child_entered, self()})

      receive do
        :release -> {:ok, %{message: "ok", tool_calls: []}}
      end
    end
  end

  defmodule CountingProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:batch_provider_invoked, self()})
      {:ok, %{message: "ok", tool_calls: []}}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-batch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp batch_loop(opts) do
    Alto.loop(BatchLoop,
      subagents:
        Alto.Subagents.bounded(
          max_depth: 1,
          max_children: Keyword.get(opts, :max_children, 8),
          max_concurrency: Keyword.get(opts, :max_concurrency, 1)
        )
    )
  end

  defp agents(count, extra \\ %{}) do
    Enum.map(1..count, fn n ->
      Map.merge(%{id: "batch-#{n}", task: "task-#{n}"}, extra)
    end)
  end

  test "runs up to concurrency in parallel, queues the rest, and preserves request order", %{
    dir: dir
  } do
    {:ok, handle} =
      Alto.Contrib.start(%{agents: agents(3)},
        loop: batch_loop(max_concurrency: 2),
        provider: {BlockingProvider, test_pid: self()},
        session: :new,
        session_dir: dir
      )

    assert_receive {:batch_child_entered, first}, 5_000
    assert_receive {:batch_child_entered, second}, 5_000
    refute_receive {:batch_child_entered, _third}, 100

    send(first, :release)
    send(second, :release)
    assert_receive {:batch_child_entered, third}, 5_000
    send(third, :release)

    assert %Alto.Runner.Result{status: :ok} = result = Alto.await(handle, 10_000)
    assert {:completed, %{results: results}} = result.output
    assert Enum.map(results, & &1.id) == ["batch-1", "batch-2", "batch-3"]
    assert Enum.all?(results, &(&1.status == :ok))
  end

  test "the parent budget caps aggregate child model requests", %{dir: dir} do
    %Alto.Runner.Result{status: :ok} =
      result =
      Alto.Contrib.run(%{agents: agents(3)},
        loop: batch_loop(max_concurrency: 3),
        provider: {CountingProvider, test_pid: self()},
        max_model_requests: 2,
        session: :new,
        session_dir: dir
      )

    assert {:completed, %{results: results}} = result.output
    assert_receive {:batch_provider_invoked, _}, 2_000
    assert_receive {:batch_provider_invoked, _}, 2_000
    refute_receive {:batch_provider_invoked, _}, 100
    assert Enum.count(results, &(&1.status == :ok)) == 2
    assert Enum.count(results, &(&1.status == :error)) == 1
  end

  test "duplicate ids reject the entire batch before dispatch", %{dir: dir} do
    duplicate = [%{id: "same", task: "a"}, %{id: "same", task: "b"}]

    assert %Alto.Runner.Result{status: :error, reason: {:invalid_spawn_agents, _reason}} =
             _result =
             Alto.Contrib.run(%{agents: duplicate},
               loop: batch_loop(max_concurrency: 2),
               provider: {CountingProvider, test_pid: self()},
               session: :new,
               session_dir: dir
             )

    refute_receive {:batch_provider_invoked, _}, 100
  end

  test "exceeding max_children rejects the entire batch before dispatch", %{dir: dir} do
    assert %Alto.Runner.Result{status: :error, reason: {:invalid_spawn_agents, _reason}} =
             _result =
             Alto.Contrib.run(%{agents: agents(3)},
               loop: batch_loop(max_children: 2),
               provider: {CountingProvider, test_pid: self()},
               session: :new,
               session_dir: dir
             )

    refute_receive {:batch_provider_invoked, _}, 100
  end

  test "child requests use one atom-keyed schema and canonical nullable fields" do
    request = %{
      id: "child",
      task: false,
      max_steps: nil,
      tools: :inherit,
      loop: nil,
      profile_key: nil,
      system_prompt: nil,
      model_tools: [:read_file, "read_file"]
    }

    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run(%{agents: [request]},
               loop: batch_loop([]),
               tools: [Alto.Contrib.Tools.ReadFile],
               provider: {CountingProvider, test_pid: self()}
             )

    assert {:completed, %{results: [%{status: :ok}]}} = result.output
    assert_received {:batch_provider_invoked, _}

    for invalid <- [
          %{"id" => "child", "task" => "work"},
          %{"extra" => true, id: "child", task: "work"},
          %{id: "", task: "work"},
          %{id: <<255>>, task: "work"},
          %{id: "child", task: nil},
          %{id: "child", task: ""},
          %{id: "child", task: "work", max_steps: 0},
          %{id: "child", task: "work", provider: nil},
          %{id: "child", task: "work", profile_key: ""},
          %{id: "child", task: "work", model: String.duplicate("x", 257)},
          %{id: "child", task: "work", system_prompt: String.duplicate("x", 64_001)},
          %{id: "child", task: "work", model_tools: [""]},
          %{id: "child", task: "work", model_tools: [<<255>>]},
          %{id: "child", task: "work", model_tools: [42]}
        ] do
      assert %Alto.Runner.Result{status: :error, reason: {:invalid_spawn_agents, _}} =
               Alto.Contrib.run(%{agents: [invalid]},
                 loop: batch_loop([]),
                 provider: {CountingProvider, test_pid: self()}
               )
    end

    refute_receive {:batch_provider_invoked, _}, 100
  end

  test "parent cancellation stops active children and never starts queued work", %{dir: dir} do
    {:ok, handle} =
      Alto.Contrib.start(%{agents: agents(3)},
        loop: batch_loop(max_concurrency: 2),
        provider: {BlockingProvider, test_pid: self()},
        session: :new,
        session_dir: dir
      )

    assert_receive {:batch_child_entered, first}, 5_000
    assert_receive {:batch_child_entered, second}, 5_000
    first_ref = Process.monitor(first)
    second_ref = Process.monitor(second)
    refute_receive {:batch_child_entered, _third}, 100

    assert :ok = Alto.cancel(handle, :operator_stop)

    assert %Alto.Runner.Result{status: :cancelled, reason: :operator_stop} =
             _result = Alto.await(handle, 10_000)

    assert_receive {:DOWN, ^first_ref, :process, ^first, _reason}, 2_000
    assert_receive {:DOWN, ^second_ref, :process, ^second, _reason}, 2_000
    refute_receive {:batch_child_entered, _third}, 100
  end
end
