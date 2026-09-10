defmodule Alto.Runner.DurableDeadlineTest do
  use ExUnit.Case, async: false

  alias Alto.OperationLog
  alias Alto.Runner.Budget
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.Journal

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-deadline-#{System.unique_integer([:positive])}")
    ledger = start_supervised!({OperationLog, id: "deadline", name: nil, dir: dir})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{ledger: ledger}
  end

  test "a suspended budget ledger is bounded by the run deadline", %{ledger: ledger} do
    assert {:ok, account} = Account.open(ledger, "budget", max_effects: 2, max_model_requests: 2)
    deadline = System.monotonic_time(:millisecond) + 50
    :sys.suspend(ledger)
    started = System.monotonic_time(:millisecond)

    assert {:error, :run_timeout} = Account.take(account, :effect, 2, deadline)
    assert System.monotonic_time(:millisecond) - started < 250

    :sys.resume(ledger)
    assert {:ok, %{packet: packet}} = Account.read(account)
    assert packet["effects_used"] == 0
  end

  test "a suspended journal ledger is bounded by its absolute deadline", %{ledger: ledger} do
    assert {:ok, batch} = Journal.open(ledger, "batch", ["child"])
    deadline = System.monotonic_time(:millisecond) + 50
    stalled = %{batch | deadline: deadline}
    :sys.suspend(ledger)
    started = System.monotonic_time(:millisecond)

    assert {:error, :run_timeout} = Journal.read(stalled)
    assert System.monotonic_time(:millisecond) - started < 250
    :sys.resume(ledger)
  end

  test "a run deadline does not permanently expire a durable account", %{ledger: ledger} do
    assert {:ok, account} =
             Account.open(ledger, "reusable", max_effects: 3, max_model_requests: 3)

    assert {:ok, budget} =
             Budget.new(
               budget_account: account,
               max_effects: 3,
               max_model_requests: 3,
               run_timeout: 50
             )

    Process.sleep(60)
    assert {:error, :run_timeout} = Account.take(account, :effect, 3, budget.deadline)

    assert {:ok, reopened} =
             Account.open(ledger, "reusable", max_effects: 3, max_model_requests: 3)

    assert {:ok, %{packet: packet}} = Account.read(reopened)
    assert packet["effects_used"] == 0
  end

  test "cancellation interrupts stalled account attachment", %{ledger: ledger} do
    {:ok, account} = Account.open(ledger, "attachment", max_effects: 3, max_model_requests: 3)
    :sys.suspend(ledger)

    try do
      {:ok, handle} = Alto.start("unused", budget_account: account, run_timeout: 10_000)
      assert {:error, :await_timeout} = Alto.await(handle, 20)
      assert :ok = Alto.cancel(handle, :storage_stalled)
      assert {:error, {:cancelled, :storage_stalled}, _} = Alto.await(handle, 500)
    after
      :sys.resume(ledger)
    end
  end

  test "cancellation interrupts a stalled reservation between effects", %{ledger: ledger} do
    {:ok, account} = Account.open(ledger, "reservation", max_effects: 3, max_model_requests: 3)
    # Manual admission lets initialization settle before the ledger is stalled.
    {:ok, handle} =
      Alto.start(%{},
        runner: Alto.Runner.Stepped,
        runner_options: [mode: :manual, controller: self()],
        loop: Alto.rule_loop(steps: ["missing_tool"]),
        budget_account: account,
        run_timeout: 10_000
      )

    assert_receive {:alto_step_ready, ticket, _}
    :sys.suspend(ledger)

    try do
      Alto.Runner.Stepped.advance(ticket)
      assert {:error, :await_timeout} = Alto.await(handle, 20)
      Alto.cancel(handle, :storage_stalled)
      assert {:error, {:cancelled, :storage_stalled}, _} = Alto.await(handle, 500)
    after
      :sys.resume(ledger)
    end

    assert {:ok, %{packet: packet}} = Account.read(account)
    assert packet["effects_used"] == 0
  end
end
