defmodule Alto.Context.WindowTest do
  use ExUnit.Case, async: true

  alias Alto.Context.{Policy, Window}

  test "admission applies the smaller model or user cap before reserving output" do
    policy =
      Window.new(max_tokens: 200_000, reserve_output: 16_000, estimator: fn _ -> 120_000 end)

    request = %{messages: [], tools: []}

    assert {:error, {:context_limit, %{input_upper_bound: 120_000, budget: 112_000}}} =
             Policy.check(policy, request, %{context_window: 128_000})

    assert {:ok, %{context_window: 200_000, input_tokens: 184_000, reserve_output: 16_000}} =
             Policy.check(policy, request, %{context_window: 1_000_000})
  end

  test "observed prefix counts prevent premature compaction but edits invalidate the observation" do
    options = [max_tokens: 1100, compact_at: 0.75]
    policy = Window.new(options ++ [usage_estimation: true])

    messages = [
      %{"role" => "system", "content" => String.duplicate("static ", 100)},
      %{"role" => "user", "content" => "review"}
    ]

    tools = [%{"function" => %{"name" => "read"}}]
    observation = %{messages: messages, tools: tools, input_tokens: 200}
    suffix = %{"role" => "assistant", "content" => String.duplicate("word ", 30)}
    request = %{messages: messages ++ [suffix], tools: tools, context_observation: observation}
    assert {:ok, budget} = Policy.check(policy, request, %{})
    refute Map.get(budget, :pressure, false)

    assert {:ok, %{pressure: true}} =
             Policy.check(Window.new(options), request, %{})

    assert {:ok, %{pressure: true}} =
             Policy.check(
               policy,
               %{request | tools: tools ++ [%{"function" => %{"name" => "edit"}}]},
               %{}
             )

    assert {:ok, %{pressure: true}} =
             Policy.check(
               policy,
               %{
                 request
                 | messages: [
                     %{"role" => "system", "content" => String.duplicate("changed", 100)}
                     | tl(request.messages)
                   ]
               },
               %{}
             )
  end
end
