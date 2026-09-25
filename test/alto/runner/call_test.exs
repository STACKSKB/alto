defmodule Alto.Runner.CallTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.Execution.Call

  test "completion removes its monitor and leaves unrelated cancellation messages alone" do
    other = make_ref()
    send(self(), {:alto_cancel, other, :unrelated})
    send(self(), {:alto_cancel, nil, :disabled})
    assert {:ok, :value} = Call.run(fn -> :value end, 1_000, nil)
    assert_receive {:alto_cancel, ^other, :unrelated}
    assert_receive {:alto_cancel, nil, :disabled}
    refute_receive {:DOWN, _, :process, _, _}
  end

  test "cancellation during setup reports an event and a rejected-before-dispatch result" do
    owner = self()
    ref = make_ref()
    send(self(), {:alto_cancel, ref, :stop_before_start})

    assert {:error, {:cancelled, :stop_before_start}, result} =
             Alto.run("task", cancel_ref: ref, event_sink: &send(owner, {:event, &1}))

    assert result.verdict == :rejected_before_dispatch
    assert [event] = result.events
    assert event.type == :run_cancelled
    assert event.data == %{reason: :stop_before_start}
    assert_receive {:event, ^event}
    refute_receive {:event, _}
  end

  for mode <- [:timeout, :cancel] do
    @tag mode: mode
    test "#{mode} terminates the participant before returning", %{mode: mode} do
      owner = self()
      cancel_ref = make_ref()
      timeout = if mode == :timeout, do: 100, else: 5_000

      caller =
        Task.async(fn ->
          Call.run(
            fn ->
              send(owner, {:participant, self()})
              Process.sleep(:infinity)
            end,
            timeout,
            cancel_ref
          )
        end)

      assert_receive {:participant, worker}
      monitor = Process.monitor(worker)
      if mode == :cancel, do: send(caller.pid, {:alto_cancel, cancel_ref, :user})
      expected = if mode == :cancel, do: {:cancelled, :user}, else: {:error, :timeout}
      assert Task.await(caller) == expected
      refute Process.alive?(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, reason}
      assert reason in [:killed, :noproc]
    end
  end
end
