defmodule Alto.Runner.SerialManualTest do
  use ExUnit.Case, async: true

  defmodule ManualTool do
    use Alto.Tool, name: :manual_echo, execution_mode: :parallel, approval: :never

    @impl true
    def schema(_opts),
      do: %{description: "Manual runner tool.", parameters: %{type: "object", properties: %{}}}

    @impl true
    def run(_arguments, context, _opts) do
      if pid = context.metadata[:test_pid], do: send(pid, {:tool_ran, :manual})
      {:ok, :manual_ok}
    end
  end

  defp base_opts(extra) do
    Keyword.merge(
      [
        provider: nil,
        tool_context_metadata: %{test_pid: self()}
      ],
      extra
    )
  end

  test "manual Serial tickets admit one frame and stale tickets do not advance later frames" do
    assert {:ok, handle} =
             Alto.start(
               %{},
               base_opts(
                 loop: Alto.rule_loop(steps: ["manual_echo", "manual_echo"]),
                 tools: [ManualTool],
                 runner_options: [mode: :manual, controller: self()]
               )
             )

    assert_receive {:alto_step_ready, first, %{pending_effects: 1}}, 2_000
    refute_receive {:tool_ran, _}, 100
    assert :ok = Alto.Runner.Serial.advance(first)
    assert_receive {:tool_ran, :manual}, 2_000

    # The actual tool has no side effect; receiving the next ticket proves the
    # first frame was admitted. A duplicate first ticket must be ignored.
    assert_receive {:alto_step_ready, second, _}, 2_000
    assert :ok = Alto.Runner.Serial.advance(first)
    refute_receive {:tool_ran, _}, 100
    assert :ok = Alto.Runner.Serial.advance(second)
    assert_receive {:tool_ran, :manual}, 2_000
    assert {:ok, %{output: [:manual_ok, :manual_ok]}} = Alto.await(handle, 2_000)

    assert {:ok, cancel_handle} =
             Alto.start(
               %{},
               base_opts(
                 loop: Alto.rule_loop(steps: ["manual_echo"]),
                 tools: [ManualTool],
                 runner_options: [mode: :manual, controller: self()],
                 run_timeout: 5_000
               )
             )

    assert_receive {:alto_step_ready, _cancel_ticket, _}, 2_000
    assert :ok = Alto.cancel(cancel_handle, :manual_cancel)
    assert {:error, {:cancelled, :manual_cancel}, _} = Alto.await(cancel_handle, 2_000)

    assert {:ok, deadline_handle} =
             Alto.start(
               %{},
               base_opts(
                 loop: Alto.rule_loop(steps: ["manual_echo"]),
                 tools: [ManualTool],
                 runner_options: [mode: :manual, controller: self()],
                 run_timeout: 50
               )
             )

    assert_receive {:alto_step_ready, _deadline_ticket, _}, 2_000
    assert {:error, :run_timeout, _} = Alto.await(deadline_handle, 2_000)

    parent = self()

    controller =
      spawn(fn ->
        receive do
          message ->
            send(parent, message)
            Process.sleep(:infinity)
        end
      end)

    assert {:ok, owner_handle} =
             Alto.start(
               %{},
               base_opts(
                 loop: Alto.rule_loop(steps: ["manual_echo"]),
                 tools: [ManualTool],
                 runner_options: [mode: :manual, controller: controller]
               )
             )

    assert_receive {:alto_step_ready, _owner_ticket, _}, 2_000
    Process.exit(controller, :kill)
    assert {:error, {:cancelled, {:step_controller_down, _}}, _} = Alto.await(owner_handle, 2_000)
  end
end
