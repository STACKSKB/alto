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

  test "opening persists one initialized checkpoint and one attempt", %{ledger: ledger} do
    assert {:ok, account} =
             Account.open(ledger, "atomic-open", max_effects: 2, max_model_requests: 3)

    assert {:ok, %{revision: 1, packet: packet, state: :active}} = Account.read(account)
    assert packet["effects_used"] == 0
    assert packet["model_requests_used"] == 0
    assert OperationLog.request(ledger, {:attempts, "atomic-open"}) == 1

    assert {:ok, reopened} =
             Account.open(ledger, "atomic-open", max_effects: 2, max_model_requests: 3)

    assert Account.identity(reopened) == Account.identity(account)
    assert {:ok, %{revision: 1}} = Account.read(reopened)
    assert OperationLog.request(ledger, {:attempts, "atomic-open"}) == 1
  end

  test "unlimited model policy opens a portable account but cannot widen an existing cap", %{
    ledger: ledger
  } do
    assert {:ok, account} =
             Account.open(ledger, "unlimited", max_effects: 10, max_model_requests: :infinity)

    assert {:ok, %{packet: packet}} = Account.read(account)
    assert is_integer(packet["max_model_requests"])
    assert {:ok, _} = Account.tighten(account, 10, 1)

    assert {:ok, reopened} =
             Account.open(ledger, "unlimited", max_effects: 10, max_model_requests: :infinity)

    assert :ok = Account.take(reopened, :model, packet["max_model_requests"])

    assert {:error, {:model_request_limit, 1}} =
             Account.take(reopened, :model, packet["max_model_requests"])
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
    attempts = OperationLog.request(ledger, {:attempts, "lookup"})

    assert {:ok, looked_up, snapshot} = Account.lookup(ledger, "lookup")
    assert Account.identity(looked_up) == Account.identity(account)
    assert snapshot == before
    assert OperationLog.request(ledger, {:attempts, "lookup"}) == attempts
    assert Account.read(account) == {:ok, before}

    assert {:error, :not_found} = Account.lookup(ledger, "missing")
    assert {:error, :invalid_retained_options} = Account.lookup(ledger, "lookup", typo: 1)
    assert :ok = OperationLog.request(ledger, {:intent, "foreign", "other_kind", nil, %{}})
    assert {:error, :invalid_retained_cell} = Account.lookup(ledger, "foreign")

    assert :ok =
             OperationLog.request(
               ledger,
               {:intent, "malformed", Atom.to_string(Account), nil, %{}}
             )

    assert {:error, :invalid_retained_cell} = Account.lookup(ledger, "malformed")
  end

  test "a full ledger rejects another account without reserving budget", %{dir: dir} do
    {:ok, ledger} = OperationLog.start_link(id: "full", name: nil, dir: dir, max_ops: 1)
    assert {:ok, _account} = Account.open(ledger, "first", max_effects: 1, max_model_requests: 1)

    assert {:error, _reason} =
             Account.open(ledger, "second", max_effects: 1, max_model_requests: 1)

    assert [%{operation_key: "first"}] = OperationLog.request(ledger, {:entries, :all})
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
    account = %{account | deadline: System.monotonic_time(:millisecond) - 1}
    assert :ok = Account.close(account, active.revision)
    {:ok, closed} = Account.read(account)
    assert closed.state == :retired
    assert closed.packet["effects_used"] == 1
    assert closed.packet["model_requests_used"] == 1
    assert {:error, :retained_closed} = Account.take(account, :effect, 3)
    assert {:error, :retained_closed} = Account.tighten(account, 1, 1)

    assert {:ok, looked_up, %{state: :retired, revision: closed_revision}} =
             Account.lookup(ledger, "closed")

    assert Account.identity(looked_up) == Account.identity(account)
    assert closed_revision == closed.revision

    stop_supervised!(OperationLog)
    restarted = start_supervised!({OperationLog, opts})
    restored = %{account | ledger: restarted}
    {:ok, after_restart} = Account.read(restored)
    assert after_restart.state == :retired
    assert after_restart.packet == closed.packet
    assert :ok = Account.close(restored, after_restart.revision)
    assert OperationLog.request(restarted, {:attempts, "closed"}) == 2
  end

  test "failed closure append leaves the active checkpoint intact across restart", %{
    ledger: ledger,
    ledger_opts: opts,
    dir: dir
  } do
    {:ok, account} = Account.open(ledger, "closing-atomic", max_effects: 2, max_model_requests: 2)
    assert :ok = Account.take(account, :effect, 2)
    {:ok, active} = Account.read(account)
    attempts = OperationLog.request(ledger, {:attempts, account.key})
    size = File.stat!(Path.join(dir, "budget.jsonl")).size
    :sys.replace_state(ledger, fn state -> %{state | max_log_bytes: size + 1} end)

    assert {:error, {:ledger_log_too_large, _, _}} = Account.close(account, active.revision)
    assert Account.read(account) == {:ok, active}
    assert OperationLog.request(ledger, {:attempts, account.key}) == attempts

    stop_supervised!(OperationLog)
    restarted = start_supervised!({OperationLog, opts})
    restored = %{account | ledger: restarted}
    assert Account.read(restored) == {:ok, active}
    assert :ok = Account.close(restored, active.revision)

    assert {:ok, %{state: :retired, revision: revision, packet: %{"effects_used" => 1}}} =
             Account.read(restored)

    assert revision == active.revision + 1
    assert OperationLog.request(restarted, {:attempts, account.key}) == attempts + 1
  end

  test "an old account generation cannot close a replacement", %{ledger: ledger} do
    {:ok, account} = Account.open(ledger, "closure-fence", max_effects: 2, max_model_requests: 2)
    {:ok, active} = Account.read(account)
    forged = %{account | generation: String.duplicate("f", 32)}
    assert {:error, :retained_generation_mismatch} = Account.close(forged, active.revision)
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

  test "a stale cell cannot rewrite a reused key at the same revision", %{dir: dir} do
    {:ok, ledger} = OperationLog.start_link(id: "reuse-fence", name: nil, dir: dir, max_ops: 1)
    limits = [max_effects: 2, max_model_requests: 2]
    {:ok, old} = Account.open(ledger, "reused", limits)
    {:ok, stale} = Alto.Persistence.Retained.read(old)
    :ok = Account.close(old, stale.revision)
    {:ok, other} = Account.open(ledger, "evict", limits)
    {:ok, current} = Account.read(other)
    :ok = Account.close(other, current.revision)
    {:ok, replacement} = Account.open(ledger, "reused", limits)
    {:ok, before} = Account.read(replacement)
    assert before.revision == stale.revision

    assert {:error, :stale_revision} =
             Alto.Persistence.Retained.replace(old, stale, %{stale.packet | "effects_used" => 1})

    assert Account.read(replacement) == {:ok, before}
  end

  test "lookup rejects expired deadlines before reading", %{ledger: ledger} do
    assert {:ok, _account} =
             Account.open(ledger, "deadline", max_effects: 1, max_model_requests: 1)

    past = System.monotonic_time(:millisecond) - 1
    assert {:error, :run_timeout} = Account.lookup(ledger, "deadline", deadline: past)
    assert {:error, :run_timeout} = Account.lookup(ledger, "missing", deadline: past)
  end
end
