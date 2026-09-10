defmodule Alto.Runner.BudgetReservationTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget

  defp concurrent_reservations(fun, count) do
    parent = self()

    1..count
    |> Enum.map(fn _ ->
      spawn(fn -> send(parent, {:reservation, fun.()}) end)
    end)
    |> Enum.map(fn _ ->
      receive do
        {:reservation, result} -> result
      end
    end)
  end

  test "effect reservations are atomic and never oversubscribe" do
    {:ok, budget} = Budget.new(max_effects: 7, max_model_requests: 64)

    results = concurrent_reservations(fn -> Budget.take(budget) end, 64)

    assert Enum.count(results, &(&1 == :ok)) == 7
    assert Enum.count(results, &match?({:error, {:effect_limit, 7}}, &1)) == 57
    assert Budget.snapshot(budget)["effects_used"] == 7
  end

  test "model reservations are atomic and never oversubscribe" do
    {:ok, budget} = Budget.new(max_effects: 64, max_model_requests: 7)

    results = concurrent_reservations(fn -> Budget.take_model(budget) end, 64)

    assert Enum.count(results, &(&1 == :ok)) == 7
    assert Enum.count(results, &match?({:error, {:model_request_limit, 7}}, &1)) == 57
    assert Budget.snapshot(budget)["model_requests_used"] == 7
  end

  test "expired and exhausted budgets do not consume reservations" do
    {:ok, expired} = Budget.new(run_timeout: 1, max_effects: 2, max_model_requests: 2)
    Process.sleep(3)

    assert {:error, :run_timeout} = Budget.take(expired)
    assert {:error, :run_timeout} = Budget.take_model(expired)
    assert Budget.snapshot(expired)["effects_used"] == 0
    assert Budget.snapshot(expired)["model_requests_used"] == 0

    {:ok, exhausted} = Budget.new(max_effects: 1, max_model_requests: 1)
    assert :ok = Budget.take(exhausted)
    assert {:error, {:effect_limit, 1}} = Budget.take(exhausted)
    assert Budget.snapshot(exhausted)["effects_used"] == 1
  end

  test "caps above the unsigned atomics range are rejected" do
    too_large = 18_446_744_073_709_551_616

    assert {:error, {:invalid_option, :max_effects, ^too_large}} =
             Budget.new(max_effects: too_large)

    assert {:error, {:invalid_option, :max_model_requests, ^too_large}} =
             Budget.new(max_model_requests: too_large)
  end
end
