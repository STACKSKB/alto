defmodule Alto.Context.EstimatorTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Estimator

  test "Window applies tokenizer estimates at the input budget boundary" do
    policy =
      Alto.Context.Window.new(
        max_tokens: 34,
        reserve_output: 10,
        estimator: Estimator.new(tokenizer: fn _text -> 20 end, provider_overhead: 4)
      )

    assert {:ok, budget} =
             policy.check.(
               %{messages: [%{"role" => "user", "content" => "hello"}], tools: []},
               %{context_window: 100}
             )

    assert budget.input_tokens == 24

    assert {:error, {:context_limit, %{input_upper_bound: 44, budget: 24}}} =
             policy.check.(
               %{messages: [%{"content" => "hello"}, %{"content" => "again"}], tools: []},
               %{context_window: 100}
             )
  end
end
