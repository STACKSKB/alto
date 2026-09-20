defmodule Alto.PolicyCompositionTest do
  use ExUnit.Case, async: true

  defmodule Context do
    @behaviour Alto.Context.Policy
    def check(opts, request, _description) do
      send(opts[:owner], {:checked, request.messages})
      {:error, :host_context_rejected}
    end
  end

  defmodule Provider do
    def describe(_), do: %{}
    def stream(_, _, _), do: raise("must not dispatch rejected request")
  end

  defmodule Children do
    @behaviour Alto.Subagents.Policy
    def limits(_), do: %{max_depth: 2, max_children: 3, max_concurrency: 2}

    def admit(opts, agents, context) do
      send(opts[:owner], {:admitted, agents, context})
      Keyword.get(opts, :decision, :ok)
    end
  end

  defmodule BlockingChildren do
    @behaviour Alto.Subagents.Policy
    def limits(opts) do
      send(opts[:owner], {:limits_called, self()})
      if opts[:block] == :limits, do: wait()
      %{max_depth: 2, max_children: 3, max_concurrency: 2}
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
    def init(kind, _) do
      agent = %{id: "child", task: "work", loop: Alto.loop(Alto.PolicyCompositionTest.ChildLoop)}

      effect =
        if kind == :single,
          do: Alto.Effect.spawn_agent(agent),
          else: Alto.Effect.spawn_agents(%{agents: [agent]})

      Alto.Transition.continue(nil, [effect])
    end

    def handle_event(event, state, _), do: Alto.Transition.stop(state, event.type)
  end

  defmodule ChildLoop do
    @behaviour Alto.Loop
    def init(_, _), do: Alto.Transition.stop(nil, "done")
    def handle_event(_, state, _), do: Alto.Transition.stop(state, "done")
  end

  test "limits are resolved once per run instead of at every child projection" do
    loop = Alto.loop(ParentLoop, subagents: {BlockingChildren, owner: self()})
    assert {:ok, _} = Alto.run(:batch, provider: nil, loop: loop)
    assert_receive {:limits_called, _}
    assert_receive {:admission_called, _}
    refute_receive {:limits_called, _}
  end

  test "limits and both admission paths are cancellable" do
    for {kind, phase, message} <- [
          {:batch, :limits, :limits_called},
          {:single, :admit, :admission_called},
          {:batch, :admit, :admission_called}
        ] do
      loop = Alto.loop(ParentLoop, subagents: {BlockingChildren, owner: self(), block: phase})
      assert {:ok, handle} = Alto.start(kind, provider: nil, loop: loop, tool_timeout: 5_000)
      assert_receive {^message, worker}, 1_000
      monitor = Process.monitor(worker)
      Alto.cancel(handle, :test_cancel)
      result = Alto.await(handle, 1_000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      assert {:error, {:cancelled, :test_cancel}, _} = result
    end
  end

  test "child policy resolution respects the callback deadline" do
    loop = Alto.loop(ParentLoop, subagents: {BlockingChildren, owner: self(), block: :limits})

    assert {:error, {:subagent_policy_failed, :timeout}, _} =
             Alto.run(:batch, provider: nil, loop: loop, tool_timeout: 50)

    assert_receive {:limits_called, worker}
    refute Process.alive?(worker)
  end

  test "custom context policy is invoked and its rejection prevents dispatch" do
    loop = Alto.default_loop(context: {Context, owner: self()})
    assert {:error, :host_context_rejected, _} = Alto.run("hello", loop: loop, provider: Provider)
    assert_receive {:checked, [_ | _]}

    assert {:error, :invalid_context_policy, _} =
             Alto.run("hello",
               loop: Alto.default_loop(context: :not_a_policy),
               provider: Provider
             )
  end

  test "custom child admission shares the built-in authority and bounds checks" do
    policy = {Children, owner: self()}
    {:ok, budget} = Alto.Runner.Budget.new([])

    run = %{
      child_limits: Alto.Subagents.Policy.limits!(policy),
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

  test "schemas reject invalid built-in context options and custom limits" do
    assert_raise NimbleOptions.ValidationError, fn -> Alto.Context.window(reserve_output: -1) end
    assert {:error, :invalid_subagent_policy} = Alto.Subagents.Policy.validate({String, []})
  end

  test "malformed compaction lists return configuration errors before schema validation" do
    assert {:error, {:invalid_compaction, [:invalid]}, _} =
             Alto.run("hello", provider: Provider, compaction: [:invalid])
  end
end
