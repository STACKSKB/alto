defmodule Alto.Runner.DurableBudgetTest do
  use ExUnit.Case, async: true
  alias Alto.{OperationLog, Runner.Budget, Runner.Budget.Account}

  defmodule Guarded do
    @behaviour Alto.Tool
    def name, do: :guarded_budget

    def schema,
      do: %{description: "Record prepared value", parameters: %{type: "object", properties: %{}}}

    def execution_mode, do: :exclusive
    def approval, do: :required

    def prepare(_, context) do
      File.write!(Path.join(context.cwd, "prepared"), "1", [:append])
      {:ok, %{value: File.read!(Path.join(context.cwd, "input"))}, %{action: "record"}}
    end

    def run_prepared(prepared, context) do
      File.write!(Path.join(context.cwd, "output"), prepared.value, [:append])
      {:ok, prepared.value}
    end
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-durable-budget-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    ledger_opts = [id: "budgets", name: nil, dir: dir]
    ledger = start_supervised!({OperationLog, ledger_opts})
    {:ok, account} = Account.open(ledger, "tree", max_effects: 10, max_model_requests: 3)
    opts = [budget_account: account, max_effects: 10, max_model_requests: 3, run_timeout: 30_000]
    %{dir: dir, ledger: ledger, ledger_opts: ledger_opts, account: account, opts: opts}
  end

  test "restored budgets share all later reservations rather than cloning saved allowance", c do
    assert {:ok, original} = Budget.new(c.opts)
    assert :ok = Budget.take_model(original)
    saved = Budget.snapshot(original)
    assert :ok = Budget.take_model(original)
    assert {:ok, first} = Budget.restore(c.opts, saved)
    assert {:ok, second} = Budget.restore(c.opts, saved)

    results =
      for budget <- [first, second, original, first, second] do
        Task.async(fn -> Budget.take_model(budget) end)
      end
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, {:model_request_limit, 3}})) == 4
    assert Budget.snapshot(first)["model_requests_used"] == 3
    assert Budget.snapshot(second)["model_requests_used"] == 3

    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, c.ledger_opts})
    assert {:ok, account} = Account.open(ledger, "tree", max_effects: 99, max_model_requests: 99)
    assert {:ok, restored} = Budget.restore(Keyword.put(c.opts, :budget_account, account), saved)
    assert {:error, {:model_request_limit, 3}} = Budget.take_model(restored)
    assert Budget.snapshot(restored)["model_requests_used"] == 3
  end

  test "account binding and rollback checks prevent fallback to independent counters", c do
    {:ok, budget} = Budget.new(c.opts)
    :ok = Budget.take(budget)
    saved = Budget.snapshot(budget)
    assert {:error, :budget_account_mismatch} = Budget.restore([], saved)
    {:ok, other} = Account.open(c.ledger, "other", max_effects: 10, max_model_requests: 3)
    assert {:error, :budget_account_mismatch} = Budget.restore([budget_account: other], saved)

    assert {:error, :budget_account_rollback} =
             Budget.restore(c.opts, Map.put(saved, "effects_used", 2))

    assert {:error, :budget_account_mismatch} =
             Budget.restore(c.opts, Map.delete(saved, "account"))
  end

  test "tightening one restored runner constrains other existing handles", c do
    {:ok, budget} = Budget.new(c.opts)
    :ok = Budget.take_model(budget)
    saved = Budget.snapshot(budget)
    assert {:ok, _} = Budget.restore(Keyword.put(c.opts, :max_model_requests, 1), saved)
    assert {:error, {:model_request_limit, 1}} = Budget.take_model(budget)
    assert Budget.snapshot(budget)["max_model_requests"] == 1
  end

  test "an expired durable budget does not reserve and ledger loss cannot create a snapshot", c do
    {:ok, budget} = Budget.new(c.opts)
    expired = %{budget | deadline: System.monotonic_time(:millisecond) - 1}
    assert {:error, :run_timeout} = Budget.take(expired)
    assert Budget.snapshot(budget)["effects_used"] == 0
    stop_supervised!(OperationLog)
    assert {:error, _} = Budget.take(budget)
    assert_raise RuntimeError, fn -> Budget.snapshot(budget) end
    assert {:error, _} = Budget.new(c.opts)
  end

  test "approval continuation reconnects after ledger restart and retains intervening charges",
       c do
    File.write!(Path.join(c.dir, "input"), "original")

    opts =
      c.opts ++
        [
          cwd: c.dir,
          session: :new,
          session_dir: Path.join(c.dir, "sessions"),
          loop: Alto.rule_loop(steps: ["guarded_budget"]),
          tools: [Guarded],
          approval: Alto.Approvals.Checkpoint,
          checkpoint_version: "durable-budget-test"
        ]

    assert {:error, :approval_suspended, suspended} = Alto.run("{}", opts)
    packet = suspended.checkpoint |> JSON.encode!() |> JSON.decode!()
    assert packet["budget"]["effects_used"] == 1
    assert packet["budget"]["account"] == Account.identity(c.account)
    assert :ok = Account.take(c.account, :effect, 10)
    File.write!(Path.join(c.dir, "input"), "changed")
    stop_supervised!(OperationLog)
    ledger = start_supervised!({OperationLog, c.ledger_opts})
    {:ok, account} = Account.open(ledger, "tree", max_effects: 10, max_model_requests: 3)

    resumed_opts =
      opts
      |> Keyword.put(:budget_account, account)
      |> Keyword.put(:checkpoint, {packet, :approve})

    assert {:ok, completed} = Alto.run("{}", resumed_opts)
    assert completed.output == ["original"]
    assert File.read!(Path.join(c.dir, "prepared")) == "1"
    assert File.read!(Path.join(c.dir, "output")) == "original"
    assert {:ok, %{packet: current}} = Account.read(account)
    assert current["effects_used"] == 2
  end

  test "account closure fences old handles even after terminal entry eviction", c do
    ledger =
      start_supervised!({OperationLog, [id: "retired", name: nil, dir: c.dir, max_ops: 1]},
        id: :retired
      )

    {:ok, account} = Account.open(ledger, "tree", max_effects: 5, max_model_requests: 2)
    {:ok, budget} = Budget.new(budget_account: account)
    snapshot = Budget.snapshot(budget)
    {:ok, before} = Account.read(account)
    assert :ok = Budget.take(budget)
    assert {:error, :stale_revision} = Account.close(account, before.revision)
    {:ok, current} = Account.read(account)
    assert :ok = Account.close(account, current.revision)
    assert {:error, _} = Budget.take(budget)
    assert {:error, _} = Account.open(ledger, "tree", max_effects: 5, max_model_requests: 2)
    {:ok, replacement} = Account.open(ledger, "other", max_effects: 1, max_model_requests: 1)
    {:ok, replacement_state} = Account.read(replacement)
    :ok = Account.close(replacement, replacement_state.revision)
    {:ok, reused} = Account.open(ledger, "tree", max_effects: 5, max_model_requests: 2)
    refute Account.identity(reused) == Account.identity(account)
    assert {:error, :budget_account_mismatch} = Budget.restore([budget_account: reused], snapshot)
    assert {:error, _} = Account.take(account, :effect, 5)
  end

  test "concurrent opens converge on one generation and initialization never resets counters",
       c do
    opened =
      for _ <- 1..8 do
        Task.async(fn ->
          Account.open(c.ledger, "simultaneous", max_effects: 8, max_model_requests: 2)
        end)
      end
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(opened, &match?({:ok, _}, &1))
    identities = Enum.map(opened, fn {:ok, a} -> Account.identity(a) end)
    assert length(Enum.uniq(identities)) == 1
    Enum.each(opened, fn {:ok, a} -> assert :ok = Account.take(a, :effect, 8) end)
    {:ok, account} = Account.open(c.ledger, "simultaneous", max_effects: 8, max_model_requests: 2)
    assert {:error, {:effect_limit, 8}} = Account.take(account, :effect, 8)
  end
end
