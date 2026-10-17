defmodule Alto.Runner.BudgetSnapshotTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.Budget

  test "local restoration retains consumption and cannot widen saved or requested limits" do
    {:ok, budget} = Budget.new(max_effects: 3, max_model_requests: 1, run_timeout: 10_000)
    assert :ok = Budget.take(budget)
    assert :ok = Budget.take_model(budget)
    saved = Budget.snapshot(budget)

    assert {:ok, restored} =
             Budget.restore(
               [max_effects: 1, max_model_requests: :infinity, run_timeout: 5_000],
               saved
             )

    assert {:error, {:effect_limit, 1}} = Budget.take(restored)
    assert {:error, {:model_request_limit, 1}} = Budget.take_model(restored)
    assert Budget.remaining(restored) <= 5_000

    assert {:ok, expired} = Budget.restore([], Map.put(saved, "remaining_ms", 0))
    assert {:error, :run_timeout} = Budget.check(expired)
    assert {:error, :run_timeout} = Budget.take(expired)
    assert {:error, :run_timeout} = Budget.take_model(expired)
  end

  test "unlimited local model counters survive portable snapshots" do
    opts = [max_model_requests: :infinity]
    {:ok, budget} = Budget.new(opts)
    for _ <- 1..300, do: assert(:ok = Budget.take_model(budget))
    saved = budget |> Budget.snapshot() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, restored} = Budget.restore(opts, saved)
    assert Budget.snapshot(restored)["model_requests_used"] == 300
    assert :ok = Budget.take_model(restored)
  end

  test "malformed snapshots fail before creating usable counters" do
    {:ok, budget} = Budget.new([])
    saved = Budget.snapshot(budget)

    for key <- Map.keys(saved) do
      assert {:error, :invalid_snapshot} = Budget.restore([], Map.delete(saved, key))

      for invalid <- ["0", -1] do
        assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(saved, key, invalid))
      end
    end

    for key <- ["effects_used", "model_requests_used", "max_effects", "max_model_requests"] do
      assert {:error, :invalid_snapshot} =
               Budget.restore([], Map.put(saved, key, 18_446_744_073_709_551_616))
    end

    for key <- ["max_effects", "max_model_requests"] do
      assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(saved, key, 0))
    end

    assert {:error, :invalid_snapshot} = Budget.restore([], Map.put(saved, "extra", 1))
  end
end
