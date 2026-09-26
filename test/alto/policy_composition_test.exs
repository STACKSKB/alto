defmodule Alto.PolicyCompositionTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    def describe(_), do: %{}
    def stream(_, _, _), do: raise("must not dispatch rejected request")
  end

  defmodule Children do
    def policy(opts),
      do:
        Alto.Subagents.bounded(
          max_depth: 2,
          max_children: 3,
          max_concurrency: 2,
          admit: &admit(opts, &1, &2)
        )

    def admit(opts, agents, context) do
      send(opts[:owner], {:admitted, agents, context})
      Keyword.get(opts, :decision, :ok)
    end
  end

  defmodule BlockingChildren do
    def policy(opts) do
      send(opts[:owner], {:limits_called, self()})
      if opts[:block] == :limits, do: wait()

      Alto.Subagents.bounded(
        max_depth: 2,
        max_children: 3,
        max_concurrency: 2,
        admit: &admit(opts, &1, &2)
      )
    end

    def admit(opts, _, _) do
      send(opts[:owner], {:admission_called, self()})
      if opts[:block] == :admit, do: wait()
      :ok
    end

    defp wait, do: receive(do: (:release -> :ok))
  end

  defmodule ParentLoop do
    @behaviour Alto.Loop
    def init(_task, _) do
      agent = %{id: "child", task: "work", loop: Alto.loop(Alto.PolicyCompositionTest.ChildLoop)}
      {:continue, nil, [{:spawn_agents, %{agents: [agent]}}]}
    end

    def handle_event(event, state, _), do: {{:stop, event.type}, state, []}
  end

  defmodule ChildLoop do
    @behaviour Alto.Loop
    def init(_, _), do: {{:stop, "done"}, nil, []}
    def handle_event(_, state, _), do: {{:stop, "done"}, state, []}
  end

  test "limits are resolved once per run instead of at every child projection" do
    owner = self()
    loop = Alto.loop(ParentLoop, subagents: fn -> BlockingChildren.policy(owner: owner) end)
    assert %Alto.Runner.Result{status: :ok} = Alto.run(:batch, provider: nil, loop: loop)
    assert_receive {:limits_called, _}
    assert_receive {:admission_called, _}
    refute_receive {:limits_called, _}
  end

  test "limits and admission are cancellable" do
    owner = self()

    for {kind, phase, message} <- [
          {:batch, :limits, :limits_called},
          {:batch, :admit, :admission_called}
        ] do
      loop =
        Alto.loop(ParentLoop,
          subagents: fn -> BlockingChildren.policy(owner: owner, block: phase) end
        )

      assert {:ok, handle} = Alto.start(kind, provider: nil, loop: loop, tool_timeout: 5_000)
      assert_receive {^message, worker}, 1_000
      monitor = Process.monitor(worker)
      Alto.cancel(handle, :test_cancel)
      result = Alto.await(handle, 1_000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      assert %Alto.Runner.Result{status: :cancelled, reason: :test_cancel} = result
    end
  end

  test "child policy resolution respects the callback deadline" do
    owner = self()

    loop =
      Alto.loop(ParentLoop,
        subagents: fn -> BlockingChildren.policy(owner: owner, block: :limits) end
      )

    assert %Alto.Runner.Result{status: :error, reason: {:participant_failed, :timeout}} =
             Alto.run(:batch, provider: nil, loop: loop, tool_timeout: 50)

    assert_receive {:limits_called, worker}
    refute Process.alive?(worker)
  end

  test "custom context policy is invoked and its rejection prevents dispatch" do
    owner = self()

    policy = %{
      check: fn request, _description ->
        send(owner, {:checked, request.messages})
        {:error, :host_context_rejected}
      end
    }

    loop = Alto.default_loop(context: policy)

    assert %Alto.Runner.Result{status: :error, reason: :host_context_rejected} =
             Alto.run("hello", loop: loop, provider: Provider)

    assert_receive {:checked, [_ | _]}
  end

  test "custom child admission shares the built-in authority and bounds checks" do
    policy = Children.policy(owner: self())
    {:ok, budget} = Alto.Runner.Budget.new([])

    run = %{
      child_limits: policy,
      budget: budget,
      tool_timeout: 1_000,
      cancel_ref: nil,
      spec: %{subagents: policy},
      agent_depth: 0,
      max_agent_depth: 2,
      tool_specs: []
    }

    batch = %{agents: [%{id: "child", task: "hello"}]}
    assert {:ok, [_], 2} = Alto.Runner.Execution.Children.validate_batch(batch, run)
    assert_receive {:admitted, _, %{depth: 0}}

    assert {:error, :max_depth_exceeded} =
             Alto.Runner.Execution.Children.validate_batch(batch, %{run | agent_depth: 2})

    assert {:error, :tool_scope_exceeded} =
             Alto.Runner.Execution.Children.validate_batch(
               %{agents: [%{id: "child", task: "hello", tools: [Alto.Tools.WriteFile]}]},
               run
             )
  end
end
