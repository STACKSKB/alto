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

    run = %{
      policy: Alto.Subagents.Policy.limits!(policy),
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
end
