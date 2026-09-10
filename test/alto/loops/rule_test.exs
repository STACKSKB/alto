defmodule Alto.Loops.RuleTest do
  @moduledoc """
  The shipped provider-less rule loop and the queue tools it drives.

  Covers the scripted step semantics (static arguments, `:task` arguments,
  name-only steps), fail-fast on tool failure, fail-closed construction,
  and the end-to-end job-flow shape: a webhook body as the task,
  `queue_put` keyed by an order id, and `queue_cancel` as a no-op-success
  on unknown keys.
  """

  use ExUnit.Case, async: true

  alias Alto.Tool.Context

  defmodule EchoTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :echo

    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(arguments, _context), do: {:ok, %{echoed: arguments}}
  end

  defmodule BoomTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :boom

    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(_arguments, _context), do: {:error, :detonated}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-rule-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    name = :"rule_queue_#{System.unique_integer([:positive])}"
    {:ok, _queue} = Alto.Queue.start_link(id: "rule-queue", dir: dir, name: name)

    %{queue: name}
  end

  # Normalize atom keys only for the legacy shape assertions below.
  defp decode(outputs), do: outputs |> JSON.encode!() |> JSON.decode!()

  describe "step script" do
    test "runs steps in order and stops after the last tool result" do
      assert {:ok, result} =
               Alto.run(~s({"value": "b"}),
                 loop:
                   Alto.rule_loop(
                     steps: [
                       %{tool: "echo", arguments: %{"value" => "a"}},
                       "echo"
                     ]
                   ),
                 tools: [EchoTool]
               )

      assert [%{"echoed" => %{"value" => "a"}}, %{"echoed" => %{"value" => "b"}}] =
               decode(result.output)

      assert result.model_requests == 0
    end

    test "the task is the payload: name-only steps use the decoded task as arguments" do
      task = ~s({"key": "job-1", "payload": {"total": 10}})

      assert {:ok, result} =
               Alto.run(task,
                 loop: Alto.rule_loop(steps: ["echo"]),
                 tools: [EchoTool]
               )

      assert [%{"echoed" => %{"key" => "job-1", "payload" => %{"total" => 10}}}] =
               decode(result.output)
    end

    test "the :task marker passes the decoded task; a map passes as-is" do
      assert {:ok, result} =
               Alto.run(~s({"n": 1}),
                 loop:
                   Alto.rule_loop(
                     steps: [
                       %{tool: "echo", arguments: :task},
                       %{tool: "echo", arguments: %{"static" => true}}
                     ]
                   ),
                 tools: [EchoTool]
               )

      assert [%{"echoed" => %{"n" => 1}}, %{"echoed" => %{"static" => true}}] =
               decode(result.output)
    end

    test "a map task is accepted without JSON decoding" do
      assert {:ok, result} =
               Alto.run(%{"n" => 2},
                 loop: Alto.rule_loop(steps: ["echo"]),
                 tools: [EchoTool]
               )

      assert [%{"echoed" => %{"n" => 2}}] = decode(result.output)
    end
  end

  describe "fail closed" do
    test "a tool failure fails the run fast with the step identified" do
      assert {:error, {:rule_step_failed, 1, "boom", :detonated}, result} =
               Alto.run(%{},
                 loop:
                   Alto.rule_loop(steps: [%{tool: "boom"}, %{tool: "echo", arguments: :task}]),
                 tools: [BoomTool, EchoTool]
               )

      # The failing step never produced an output; the run stops there.
      assert result.output == nil
    end

    test "an empty or malformed step script fails at init" do
      for steps <- [[], "queue_put", [%{tool: 42}], [%{tool: "echo", arguments: "no"}]] do
        assert {:error, :invalid_steps, _result} =
                 Alto.run(%{}, loop: Alto.rule_loop(steps: steps), tools: [EchoTool])
      end
    end

    test "an unstructured task fails at init" do
      for task <- ["not json", 42, nil] do
        assert {:error, :invalid_task, _result} =
                 Alto.run(task, loop: Alto.rule_loop(steps: ["echo"]), tools: [EchoTool])
      end
    end

    test "an unknown tool fails the run through the normal tool pipeline" do
      assert {:error, {:rule_step_failed, 1, "missing", {:unknown_tool, "missing"}}, _result} =
               Alto.run(%{}, loop: Alto.rule_loop(steps: ["missing"]), tools: [EchoTool])
    end
  end

  describe "queue tools end to end" do
    test "queue_put keyed by the webhook task, then queue_cancel", %{queue: queue} do
      task = ~s({"key": "job-1", "payload": {"lines": 3}})

      assert {:ok, result} =
               Alto.run(task,
                 loop: Alto.rule_loop(steps: ["queue_put"]),
                 tools: [{Alto.Tools.QueuePut, queue: queue}]
               )

      assert [%{"id" => record_id, "revision" => 1, "status" => "pending"}] =
               decode(result.output)

      assert is_binary(record_id)

      assert %{pending: 1} = Alto.Queue.count(queue)

      assert {:ok, result} =
               Alto.run(~s({"key": "job-1"}),
                 loop: Alto.rule_loop(steps: ["queue_cancel"]),
                 tools: [{Alto.Tools.QueueCancel, queue: queue}]
               )

      assert [%{"cancelled" => true}] = decode(result.output)
      assert %{pending: 0} = Alto.Queue.count(queue)
    end

    test "queue_put updates a pending key in place (revision bumps)" do
      context = %Context{session_id: "test", cwd: File.cwd!(), metadata: %{}}
      dir = Path.join(System.tmp_dir!(), "alto-put-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      name = :"put_queue_#{System.unique_integer([:positive])}"
      {:ok, _} = Alto.Queue.start_link(id: "put-queue", dir: dir, name: name)

      assert {:ok, %{id: id, revision: 1}} =
               Alto.Tools.QueuePut.run(%{"key" => "k", "payload" => %{v: 1}}, context,
                 queue: name
               )

      assert {:ok, %{id: ^id, revision: 2}} =
               Alto.Tools.QueuePut.run(%{"key" => "k", "payload" => %{v: 2}}, context,
                 queue: name
               )

      assert %{pending: 1} = Alto.Queue.count(name)
    end

    test "queue_cancel of an unknown key is a no-op success" do
      context = %Context{session_id: "test", cwd: File.cwd!(), metadata: %{}}
      dir = Path.join(System.tmp_dir!(), "alto-cancel-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      name = :"cancel_queue_#{System.unique_integer([:positive])}"
      {:ok, _} = Alto.Queue.start_link(id: "cancel-queue", dir: dir, name: name)

      assert {:ok, %{cancelled: false}} =
               Alto.Tools.QueueCancel.run(%{"key" => "ghost"}, context, queue: name)
    end
  end
end
