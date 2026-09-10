defmodule Alto.Runner.SerialOutcomeTest do
  @moduledoc """
  : external effect outcome classes.

  The runner tags `tool_completed` (`:completed`) and `tool_failed`
  (`:rejected_before_dispatch` / `:failed_known` / `:unknown`) without
  changing event types, loop behavior, or tool return values. Cancellation
  after dispatch preserves uncertainty in the `run_cancelled` event's
  `in_flight` evidence; the runner never retries a tool.
  """

  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Effect.Outcome
  alias Alto.Event
  alias Alto.Transition

  defmodule OnceLoop do
    @behaviour Alto.Loop

    @impl true
    def init({name, args}, _spec) do
      Transition.continue(%{}, [
        Effect.invoke_tool(%{id: "op-1", name: name, arguments: args})
      ])
    end

    @impl true
    def handle_event(%Event{type: :tool_completed, data: data}, s, _spec) do
      Transition.stop(s, {:completed, data})
    end

    def handle_event(%Event{type: :tool_failed, data: data}, s, _spec) do
      Transition.stop(s, {:failed, data})
    end

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  defmodule OkTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :ok_tool
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :parallel
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx), do: {:ok, %{done: true}}
  end

  defmodule GuardedOkTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :ok_tool
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :parallel
    @impl true
    def run(_args, _ctx), do: {:ok, %{done: true}}
  end

  defmodule FlakyTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :flaky
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx), do: {:error, :boom}
  end

  defmodule CommitThenTimeoutTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :committer
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, opts) do
      send(Keyword.fetch!(opts, :test_pid), :committed)
      Process.sleep(5_000)
      {:ok, :unreachable}
    end
  end

  defmodule CommitThenCrashTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :crasher
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx, opts) do
      send(Keyword.fetch!(opts, :test_pid), :committed)
      exit(:boom_after_commit)
    end
  end

  defmodule BlockingTool do
    @behaviour Alto.Tool
    @impl true
    def name, do: :blocker
    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    @impl true
    def execution_mode, do: :exclusive
    @impl true
    def approval, do: :never
    @impl true
    def run(_args, _ctx), do: receive(do: (:never -> {:ok, :done}))
  end

  defmodule BlockingApproval do
    @behaviour Alto.Approval
    @impl true
    def decide(_request, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), :approval_entered)
      receive(do: (:never -> :approve))
    end
  end

  describe "vocabulary" do
    test "five classes, decided? singles out unknown" do
      assert Outcome.classes() == [
               :completed,
               :rejected_before_dispatch,
               :failed_known,
               :unknown,
               :requires_operator
             ]

      assert Outcome.decided?(:completed)
      assert Outcome.decided?(:rejected_before_dispatch)
      assert Outcome.decided?(:failed_known)
      assert Outcome.decided?(:requires_operator)
      refute Outcome.decided?(:unknown)
    end
  end

  describe "runner tags" do
    test "a returned value completes" do
      assert {:ok, result} =
               Alto.run({"ok_tool", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [OkTool]
               )

      assert {:completed, %{outcome: :completed, value: %{done: true}}} = result.output
      assert result.verdict == :completed
    end

    test "a participant error is a known failure, executed exactly once" do
      test_pid = self()

      assert {:ok, result} =
               Alto.run({"flaky", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [{FlakyTool, []}],
                 event_sink: fn event -> send(test_pid, {:event, event}) end
               )

      assert {:failed, %{outcome: :failed_known, error: :boom}} = result.output
      assert result.verdict == :failed_known

      # No implicit retry in the serial runner: one effect, one execution.
      executions =
        received_events()
        |> Enum.count(&(&1.type == :tool_started))

      assert executions == 1
    end

    test "a commit followed by a lost response is unknown, never a success" do
      assert {:ok, result} =
               Alto.run({"committer", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [{CommitThenTimeoutTool, test_pid: self()}],
                 tool_timeout: 200
               )

      assert_received :committed
      assert {:failed, %{outcome: :unknown, error: :timeout}} = result.output
      assert result.verdict == :unknown
      refute match?({:completed, _}, result.output)
    end

    test "a commit followed by a crash is unknown" do
      assert {:ok, result} =
               Alto.run({"crasher", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [{CommitThenCrashTool, test_pid: self()}]
               )

      assert_received :committed
      assert {:failed, %{outcome: :unknown}} = result.output
      assert result.verdict == :unknown
    end

    test "later uncertainty dominates earlier success after event eviction" do
      assert {:error, _reason, result} =
               Alto.run(%{},
                 loop: Alto.rule_loop(steps: ["ok_tool", "committer"]),
                 tools: [OkTool, {CommitThenTimeoutTool, test_pid: self()}],
                 tool_timeout: 50,
                 max_events: 1
               )

      assert_received :committed
      assert result.events_dropped > 0
      assert result.verdict == :unknown
    end

    test "definite pre-dispatch rejections are known" do
      # Unknown tool never dispatches.
      assert {:ok, missing} =
               Alto.run({"missing", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [OkTool]
               )

      assert {:failed, %{outcome: :rejected_before_dispatch, error: {:unknown_tool, "missing"}}} =
               missing.output

      # Undecodable native arguments never dispatch.
      defmodule BadArgsLoop do
        @behaviour Alto.Loop
        @impl true
        def init(_task, _spec) do
          Transition.continue(%{}, [Effect.invoke_tool(%{name: "ok_tool", arguments: "no"})])
        end

        @impl true
        def handle_event(%Event{type: :tool_failed, data: data}, s, _spec) do
          Transition.stop(s, data)
        end

        def handle_event(_e, s, _spec), do: Transition.continue(s)
      end

      assert {:ok, bad} = Alto.run(:go, loop: Alto.loop(BadArgsLoop), tools: [OkTool])
      assert %{outcome: :rejected_before_dispatch} = bad.output
    end

    test "an approval denial is a pre-dispatch rejection" do
      assert {:ok, result} =
               Alto.run({"ok_tool", %{}},
                 loop: Alto.loop(OnceLoop),
                 tools: [GuardedOkTool],
                 approval: Alto.Approvals.DenyAll
               )

      assert {:failed, %{outcome: :rejected_before_dispatch, error: {:approval_denied, _}}} =
               result.output
    end
  end

  describe "cancellation uncertainty" do
    test "cancel after dispatch preserves the in-flight unknown" do
      test_pid = self()

      {:ok, handle} =
        Alto.start({"blocker", %{}},
          loop: Alto.loop(OnceLoop),
          tools: [BlockingTool],
          event_sink: fn event -> send(test_pid, {:event, event}) end
        )

      # Wait until the tool is dispatched, then cancel into the dispatch.
      assert_receive {:event, %Event{type: :tool_started}}, 2_000
      assert :ok = Alto.cancel(handle, :operator_stop)
      assert {:error, {:cancelled, :operator_stop}, result} = Alto.await(handle, 5_000)

      cancelled = Enum.find(result.events, &(&1.type == :run_cancelled))

      assert %{
               reason: :operator_stop,
               in_flight: %{
                 call_id: "op-1",
                 name: "blocker",
                 outcome: :unknown
               }
             } = cancelled.data

      assert is_binary(cancelled.data.in_flight.operation_id)
      assert result.verdict == :unknown
    end

    test "cancel before dispatch carries no in-flight operation" do
      {:ok, handle} =
        Alto.start({"ok_tool", %{}},
          loop: Alto.loop(OnceLoop),
          tools: [GuardedOkTool],
          approval: {BlockingApproval, test_pid: self()}
        )

      assert_receive :approval_entered, 2_000
      assert :ok = Alto.cancel(handle, :operator_stop)
      assert {:error, {:cancelled, :operator_stop}, result} = Alto.await(handle, 5_000)

      cancelled = Enum.find(result.events, &(&1.type == :run_cancelled))
      assert %{reason: :operator_stop, in_flight: nil} = cancelled.data
    end
  end

  defp received_events do
    Enum.reduce_while(1..200, [], fn _n, acc ->
      receive do
        {:event, %Event{} = event} -> {:cont, [event | acc]}
      after
        0 -> {:halt, Enum.reverse(acc)}
      end
    end)
  end
end
