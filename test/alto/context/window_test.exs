defmodule Alto.Context.WindowTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Window

  test "caps the requested window at the model limit and reserves output" do
    policy = Alto.Context.Window.new(max_tokens: 200_000, reserve_output: 16_000)

    assert Window.resolve(policy, 128_000) == %{
             context_window: 128_000,
             input_tokens: 112_000,
             reserve_output: 16_000
           }
  end

  test "uses a lower user cap when the model supports more" do
    policy = Alto.Context.Window.new(max_tokens: 200_000, reserve_output: 16_000)

    assert Window.resolve(policy, 1_000_000).context_window == 200_000
  end

  test "observed prefix counts prevent premature compaction but edits invalidate the observation" do
    policy = Window.new(max_tokens: 1100, compact_at: 0.75, usage_estimation: true)

    messages = [
      %{"role" => "system", "content" => String.duplicate("static ", 100)},
      %{"role" => "user", "content" => "review"}
    ]

    tools = [%{"function" => %{"name" => "read"}}]
    observation = %{messages: messages, tools: tools, input_tokens: 200}
    suffix = %{"role" => "assistant", "content" => String.duplicate("word ", 30)}
    request = %{messages: messages ++ [suffix], tools: tools, context_observation: observation}
    assert {:ok, budget} = Window.check(policy, request, %{})
    refute Map.get(budget, :pressure, false)

    assert {:ok, %{pressure: true}} =
             Window.check(%{policy | usage_estimation: false}, request, %{})

    assert {:ok, %{pressure: true}} =
             Window.check(
               policy,
               %{request | tools: tools ++ [%{"function" => %{"name" => "edit"}}]},
               %{}
             )

    assert {:ok, %{pressure: true}} =
             Window.check(
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
