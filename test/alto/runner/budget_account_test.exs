defmodule Alto.Runner.BudgetAccountTest do
  use ExUnit.Case, async: true

  alias Alto.{OperationLog, Runner.Budget.Account}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-budget-account-#{System.unique_integer([:positive])}")

    ledger_opts = [id: "budget", name: nil, dir: dir, max_ops: 8]
    ledger = start_supervised!({OperationLog, ledger_opts})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, ledger: ledger, ledger_opts: ledger_opts}
  end

  test "concurrent reservations stop exactly at each cap and read counts consistently", %{
    ledger: ledger
  } do
    assert {:ok, account} = Account.open(ledger, "run-1", max_effects: 3, max_model_requests: 2)

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Account.take(account, :effect, 10) end) end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.count(results, &(&1 == :ok)) == 3
    assert Enum.count(results, &match?({:error, {:effect_limit, 3}}, &1)) == 7

    model_results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Account.take(account, :model, 10) end) end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.count(model_results, &(&1 == :ok)) == 2
    assert Enum.count(model_results, &match?({:error, {:model_request_limit, 2}}, &1)) == 6
    assert {:ok, %{packet: packet}} = Account.read(account)
    assert packet["effects_used"] == 3
    assert packet["model_requests_used"] == 2
  end

  test "reopen preserves identity and counters and high caps cannot widen it", %{
    ledger: ledger,
    ledger_opts: opts
  } do
    assert {:ok, account} = Account.open(ledger, "run-2", max_effects: 2, max_model_requests: 1)
    assert :ok = Account.take(account, :effect, 9)
    assert :ok = Account.take(account, :effect, 9)
    identity = Account.identity(account)
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, opts})

    assert {:ok, reopened} =
             Account.open(ledger, "run-2", max_effects: 99, max_model_requests: 99)

    assert Account.identity(reopened) == identity
    assert {:error, {:effect_limit, 2}} = Account.take(reopened, :effect, 99)
    assert {:error, {:effect_limit, 2}} = Account.take(reopened, :effect, 99)
  end

  test "tightening affects existing handles and caller caps cannot widen", %{ledger: ledger} do
    assert {:ok, account} = Account.open(ledger, "run-3", max_effects: 5, max_model_requests: 5)
    assert :ok = Account.take(account, :effect, 5)
    assert {:ok, state} = Account.tighten(account, 2, 1)
    assert state.packet["max_effects"] == 2
    assert :ok = Account.take(account, :effect, 5)
    assert {:error, {:effect_limit, 2}} = Account.take(account, :effect, 5)
    assert :ok = Account.take(account, :model, 99)
    assert {:error, {:model_request_limit, 1}} = Account.take(account, :model, 99)
  end

  test "wrong generation is refused without changing the account", %{ledger: ledger} do
    assert {:ok, account} = Account.open(ledger, "run-4", max_effects: 2, max_model_requests: 2)
    before = Account.read(account)
    forged = Map.put(account, :generation, "forged-generation")
    assert {:error, _reason} = Account.take(forged, :effect, 2)
    assert Account.read(account) == before
  end

  test "lookup is read-only, preserves the exact revision, and validates records and options", %{
    ledger: ledger
  } do
    assert {:ok, account} =
             Account.open(ledger, "lookup", max_effects: 2, max_model_requests: 2)

    assert :ok = Account.take(account, :effect, 2)
    {:ok, before} = Account.read(account)
    attempts = OperationLog.attempts(ledger, "lookup")

    assert {:ok, looked_up, snapshot} = Account.lookup(ledger, "lookup")
    assert Account.identity(looked_up) == Account.identity(account)
    assert snapshot == before
    assert OperationLog.attempts(ledger, "lookup") == attempts
    assert Account.read(account) == {:ok, before}

    assert {:error, :not_found} = Account.lookup(ledger, "missing")
    assert {:error, :invalid_budget_account_options} = Account.lookup(ledger, "lookup", typo: 1)
    assert :ok = OperationLog.record_intent(ledger, "foreign", "other_kind", nil, %{})
    assert {:error, :invalid_budget_account} = Account.lookup(ledger, "foreign")
    assert :ok = OperationLog.record_intent(ledger, "malformed", "alto_budget_account", nil, %{})
    assert {:error, :invalid_budget_account} = Account.lookup(ledger, "malformed")
  end

  test "a full ledger rejects another account without reserving budget", %{dir: dir} do
    {:ok, ledger} = OperationLog.start_link(id: "full", name: nil, dir: dir, max_ops: 1)
    assert {:ok, _account} = Account.open(ledger, "first", max_effects: 1, max_model_requests: 1)

    assert {:error, _reason} =
             Account.open(ledger, "second", max_effects: 1, max_model_requests: 1)

    assert OperationLog.keys(ledger) == ["first"]
  end

  test "a stopped ledger denies reservations", %{ledger: ledger} do
    assert {:ok, account} = Account.open(ledger, "dead", max_effects: 1, max_model_requests: 1)
    GenServer.stop(ledger)
    assert {:error, _reason} = Account.take(account, :effect, 1)
  end

  test "closing preserves counters, denies further grants, and is idempotent after restart", %{
    ledger: ledger,
    ledger_opts: opts
  } do
    {:ok, account} = Account.open(ledger, "closed", max_effects: 3, max_model_requests: 2)
    assert :ok = Account.take(account, :effect, 3)
    assert :ok = Account.take(account, :model, 2)
    {:ok, active} = Account.read(account)
    assert active.state == :active
    assert {:error, :stale_revision} = Account.close(account, active.revision - 1)
    assert {:error, :invalid_budget_account_revision} = Account.close(account, 0)
    assert :ok = Account.close(account, active.revision)
    {:ok, closed} = Account.read(account)
    assert closed.state == :closed
    assert closed.packet["effects_used"] == 1
    assert closed.packet["model_requests_used"] == 1
    assert {:error, :budget_account_closed} = Account.take(account, :effect, 3)
    assert {:error, :budget_account_closed} = Account.tighten(account, 1, 1)

    assert {:ok, looked_up, %{state: :closed, revision: closed_revision}} =
             Account.lookup(ledger, "closed")

    assert Account.identity(looked_up) == Account.identity(account)
    assert closed_revision == closed.revision

    stop_supervised!(OperationLog)
    restarted = start_supervised!({OperationLog, opts})
    restored = %{account | ledger: restarted}
    {:ok, after_restart} = Account.read(restored)
    assert after_restart.state == :closed
    assert after_restart.packet == closed.packet
    assert :ok = Account.close(restored, after_restart.revision)
    assert OperationLog.attempts(restarted, "closed") == 2
  end

  test "interrupted closure recovers after decision and after attempt", %{
    ledger: ledger,
    ledger_opts: opts
  } do
    for {key, record_attempt?} <- [{"closing-decision", false}, {"closing-attempt", true}] do
      {:ok, account} = Account.open(ledger, key, max_effects: 2, max_model_requests: 2)
      assert :ok = Account.take(account, :effect, 2)
      {:ok, active} = Account.read(account)

      assert {:ok, _} =
               OperationLog.resume_checkpoint(ledger, key, active.revision, %{
                 "action" => "close_budget",
                 "generation" => account.generation
               })

      if record_attempt?, do: :ok = OperationLog.record_attempt(ledger, key, "close-budget")
      assert {:ok, %{state: :closing}} = Account.read(account)
      assert {:error, :budget_account_closed} = Account.take(account, :effect, 2)
    end

    stop_supervised!(OperationLog)
    restarted = start_supervised!({OperationLog, opts})

    for key <- ["closing-decision", "closing-attempt"] do
      {:ok, entry} = OperationLog.recovery(restarted, key)

      account = %Account{
        ledger: restarted,
        key: key,
        generation: entry.recovery["generation"]
      }

      {:ok, closing} = Account.read(account)
      assert closing.state == :closing
      assert :ok = Account.close(account, closing.revision)

      assert {:ok, %{state: :closed, packet: %{"effects_used" => 1}}} =
               Account.read(account)

      assert OperationLog.attempts(restarted, key) == 2
    end
  end

  test "an old account generation cannot close a replacement", %{ledger: ledger} do
    {:ok, account} = Account.open(ledger, "closure-fence", max_effects: 2, max_model_requests: 2)
    {:ok, active} = Account.read(account)
    forged = %{account | generation: String.duplicate("f", 32)}
    assert {:error, :budget_account_mismatch} = Account.close(forged, active.revision)
    assert Account.read(account) == {:ok, active}
  end

  test "closure frees capacity only after the terminal outcome", %{dir: dir} do
    {:ok, ledger} = OperationLog.start_link(id: "close-capacity", name: nil, dir: dir, max_ops: 1)
    {:ok, account} = Account.open(ledger, "first", max_effects: 1, max_model_requests: 1)
    {:ok, active} = Account.read(account)

    assert {:error, :ledger_full} =
             Account.open(ledger, "second", max_effects: 1, max_model_requests: 1)

    assert :ok = Account.close(account, active.revision)

    assert {:ok, _second} =
             Account.open(ledger, "second", max_effects: 1, max_model_requests: 1)

    assert {:error, :not_found} = Account.read(account)
  end

  test "lookup rejects expired deadlines before reading", %{ledger: ledger} do
    assert {:ok, _account} =
             Account.open(ledger, "deadline", max_effects: 1, max_model_requests: 1)

    past = System.monotonic_time(:millisecond) - 1
    assert {:error, :run_timeout} = Account.lookup(ledger, "deadline", deadline: past)
    assert {:error, :run_timeout} = Account.lookup(ledger, "missing", deadline: past)
  end
end
