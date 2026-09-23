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

  test "works directly as a Window estimator and keeps provider usage separate" do
    policy =
      Alto.Context.window(
        max_tokens: 100,
        reserve_output: 10,
        estimator: Estimator.new(tokenizer: fn _text -> 20 end, provider_overhead: 4)
      )

    assert {:ok, budget} =
             Alto.Context.Window.check(
               policy,
               %{messages: [%{"role" => "user", "content" => "hello"}], tools: []},
               %{context_window: 100}
             )

    assert budget.input_tokens == 90
  end

  test "rejects tokenizer results that cannot form a bound" do
    assert_raise ArgumentError, ~r/tokenizer must return a non-negative integer/, fn ->
      Estimator.estimate(%{messages: [%{"x" => 1}], tools: []}, tokenizer: fn _ -> :unknown end)
    end
  end
end
