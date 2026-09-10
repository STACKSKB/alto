defmodule Alto.Runner.ExecutionComponentsTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.{Model, Tool}
  alias Alto.Tool.Context

  defmodule PreparedTool do
    def prepare(arguments, _context), do: {:ok, {:prepared, arguments}, %{resolved: true}}
    def run_prepared({:prepared, arguments}, _context), do: {:ok, arguments}
    def execution_mode, do: :exclusive
  end

  defmodule ScriptedProvider do
    def stream(_request, _sink, opts) do
      attempt = Agent.get_and_update(opts[:agent], fn n -> {n, n + 1} end)
      opts[:script].(attempt)
    end
  end

  defp budget, do: elem(Budget.new(max_model_requests: 20, run_timeout: 30_000), 1)

  defp tool_caps(opts \\ []) do
    %Tool.Capabilities{
      tools: %{},
      approval: {Alto.Approvals.DenyAll, []},
      context: %Context{session_id: "run-test", cwd: File.cwd!(), metadata: %{}},
      budget: budget(),
      event_sink: Keyword.get(opts, :event_sink)
    }
  end

  test "tool preparation passes one opaque value through invocation" do
    tool = %{
      module: PreparedTool,
      opts: [],
      preparation: :arity2,
      execution_mode: :exclusive,
      approval: :never
    }

    caps = tool_caps()

    assert {:ok, prepared, %{resolved: true}} = Tool.prepare(tool, %{"x" => 1}, caps)
    assert {:ok, {:ok, %{"x" => 1}}} = Tool.invoke(tool, prepared, caps)
  end

  test "tool approval uses the operation id and emits the boundary events" do
    tool = %{
      module: PreparedTool,
      opts: [],
      preparation: :arity2,
      execution_mode: :exclusive,
      approval: :required
    }

    parent = self()

    caps = %{
      tool_caps(event_sink: fn event -> send(parent, {:event, event}) end)
      | approval: {Alto.Approvals.AllowAll, []}
    }

    assert :ok =
             Tool.authorize(
               "call-1",
               "prepared",
               %{},
               %{resolved: true},
               tool,
               caps,
               "run-test:op-1"
             )

    assert_receive {:event, %Alto.Event{type: :approval_requested, data: %{request: request}}}
    assert request.id == "run-test:op-1"
    assert_receive {:event, %Alto.Event{type: :approval_resolved, data: %{decision: :approved}}}
  end

  test "model transport retries only retryable failures" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    parent = self()

    script = fn
      0 -> {:error, {:transport_error, :econnrefused}}
      1 -> {:ok, %{message: "done", tool_calls: []}}
    end

    caps = %Model.Capabilities{
      budget: budget(),
      cancel_ref: nil,
      provider_timeout: 2_000,
      provider_retries: 2,
      event_sink: fn event -> send(parent, {:event, event}) end
    }

    assert {:ok, {:ok, %{message: "done"}}} =
             Model.stream(
               ScriptedProvider,
               %{messages: [], tools: []},
               fn _ -> :ok end,
               [agent: agent, script: script],
               caps,
               1
             )

    assert Agent.get(agent, & &1) == 2
    assert_receive {:event, %Alto.Event{type: :model_retry, data: %{attempt: 1, max_attempts: 3}}}
  end

  test "model transport does not retry client errors" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    parent = self()

    caps = %Model.Capabilities{
      budget: budget(),
      cancel_ref: nil,
      provider_timeout: 2_000,
      provider_retries: 4,
      event_sink: fn event -> send(parent, {:event, event}) end
    }

    assert {:ok, {:error, {:http_error, 400, _}}} =
             Model.stream(
               ScriptedProvider,
               %{messages: [], tools: []},
               fn _ -> :ok end,
               [agent: agent, script: fn _ -> {:error, {:http_error, 400, %{}}} end],
               caps,
               1
             )

    assert Agent.get(agent, & &1) == 1
    refute_receive {:event, %Alto.Event{type: :model_retry}}
  end
end
