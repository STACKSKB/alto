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
end
