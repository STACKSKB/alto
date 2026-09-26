defmodule Alto.Context.EstimatorTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Estimator

  test "composes tokenizer counts with provider and model framing" do
    estimator =
      Estimator.new(
        tokenizer: fn text -> byte_size(text) end,
        provider_overhead: 10,
        message_overhead: 2,
        tool_overhead: 3,
        model: "claude-sonnet",
        model_overhead: %{"claude-sonnet" => 7}
      )

    input = %{
      messages: [%{"role" => "user", "content" => "hi"}],
      tools: [%{"type" => "function", "function" => %{"name" => "read"}}]
    }

    expected =
      10 + 7 +
        byte_size(JSON.encode!(hd(input.messages))) + 2 +
        byte_size(JSON.encode!(hd(input.tools))) + 3

    assert estimator.(input) == expected
  end

  test "Window applies tokenizer estimates at the input budget boundary" do
    policy =
      Alto.Context.Window.new(
        max_tokens: 34,
        reserve_output: 10,
        estimator: Estimator.new(tokenizer: fn _text -> 20 end, provider_overhead: 4)
      )

    assert {:ok, budget} =
             Alto.Context.Policy.check(
               policy,
               %{messages: [%{"role" => "user", "content" => "hello"}], tools: []},
               %{context_window: 100}
             )

    assert budget.input_tokens == 24

    assert {:error, {:context_limit, %{input_upper_bound: 44, budget: 24}}} =
             Alto.Context.Policy.check(
               policy,
               %{messages: [%{"content" => "hello"}, %{"content" => "again"}], tools: []},
               %{context_window: 100}
             )
  end

  test "rejects tokenizer results that cannot form a bound" do
    estimator = Estimator.new(tokenizer: fn _ -> :unknown end)

    assert_raise ArgumentError, ~r/tokenizer must return a non-negative integer/, fn ->
      estimator.(%{messages: [%{"x" => 1}], tools: []})
    end
  end
end
