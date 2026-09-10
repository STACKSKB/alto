defmodule Alto.Runner.BudgetSnapshotTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget

  test "snapshot and restore preserve shared counters" do
    {:ok, budget} = Budget.new(max_effects: 5, max_model_requests: 3, run_timeout: 10_000)
    assert :ok = Budget.take(budget)
    assert :ok = Budget.take_model(budget)

    snapshot = Budget.snapshot(budget)
    assert snapshot["effects_used"] == 1
    assert snapshot["model_requests_used"] == 1

    {:ok, restored} =
      Budget.restore([max_effects: 5, max_model_requests: 3, run_timeout: 10_000], snapshot)

    assert Budget.snapshot(restored)["effects_used"] == 1
    assert Budget.snapshot(restored)["model_requests_used"] == 1
  end

  test "restore never widens caps or remaining time" do
    snapshot = %{
      "effects_used" => 0,
      "model_requests_used" => 0,
      "max_effects" => 100,
      "max_model_requests" => 100,
      "remaining_ms" => 10_000
    }

    {:ok, restored} =
      Budget.restore([max_effects: 2, max_model_requests: 3, run_timeout: 100], snapshot)

    actual = Budget.snapshot(restored)
    assert actual["max_effects"] == 2
    assert actual["max_model_requests"] == 3
    assert actual["remaining_ms"] <= 100
  end

  test "exhausted time remains exhausted" do
    snapshot = %{
      "effects_used" => 0,
      "model_requests_used" => 0,
      "max_effects" => 1,
      "max_model_requests" => 1,
      "remaining_ms" => 0
    }

    {:ok, restored} = Budget.restore([], snapshot)
    assert {:error, :run_timeout} = Budget.check(restored)
    assert {:error, :run_timeout} = Budget.take(restored)
  end

  test "restore rejects malformed snapshots" do
    base = %{
      "effects_used" => 0,
      "model_requests_used" => 0,
      "max_effects" => 1,
      "max_model_requests" => 1,
      "remaining_ms" => 0
    }

    assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(base, "extra", 1))
    assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(base, "effects_used", -1))
    assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(base, "max_effects", 0))
    assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(base, "remaining_ms", -1))
  end
end
