defmodule Alto.UsageTest do
  use ExUnit.Case, async: true

  alias Alto.Usage

  test "latest cache rate is separate from cumulative cold-start costs" do
    cold = Alto.Usage.normalize(%{"prompt_tokens" => 1000})

    warm =
      Alto.Usage.normalize(%{
        "prompt_tokens" => 2000,
        "prompt_tokens_details" => %{"cached_tokens" => 1900}
      })

    usage = Alto.Usage.merge(cold, warm)
    assert Alto.Usage.last_cache_hit_rate(usage) == 95.0
    assert Alto.Usage.cache_hit_rate(usage) < 64
    assert Alto.Usage.last_cache_hit_rate(Alto.Usage.to_map(usage)) == 95.0
  end

  test "normalizes common token and cache fields" do
    openai =
      Usage.normalize(%{
        "prompt_tokens" => 1_000,
        "completion_tokens" => 80,
        "total_tokens" => 1_080,
        "prompt_tokens_details" => %{"cached_tokens" => 750}
      })

    assert openai.input_tokens == 1_000
    assert openai.output_tokens == 80
    assert openai.cached_input_tokens == 750
    assert Usage.cache_hit_rate(openai) == 75.0

    anthropic =
      Usage.normalize(%{
        "input_tokens" => 400,
        "output_tokens" => 50,
        "cache_read_input_tokens" => 200
      })

    assert anthropic.input_tokens == 600
    assert Float.round(Usage.cache_hit_rate(anthropic), 1) == 33.3
    assert Usage.merge(openai, anthropic).total_tokens == 1_730
  end

  test "unknown or absent usage is zero and does not invent a cache rate" do
    assert Usage.new() == Usage.normalize(nil)
    assert Usage.cache_hit_rate(Usage.new()) == 0.0
  end

  test "preserves explicit zero fields while defaulting only missing fields" do
    assert Usage.normalize(%{"input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 0}).total_tokens ==
             0

    assert Usage.from_map(%{
             input_tokens: 12,
             total_tokens: 0,
             last_input_tokens: 0,
             cached_input_tokens: 99,
             last_cached_input_tokens: 99
           }) == %Usage{
             input_tokens: 12,
             output_tokens: 0,
             total_tokens: 0,
             cached_input_tokens: 12,
             last_input_tokens: 0,
             last_cached_input_tokens: 0,
             requests: 0
           }

    assert Usage.from_map(%{"input_tokens" => 12}).last_input_tokens == 12
  end

  test "codex snapshots preserve zeros and do not claim a request count" do
    usage =
      Usage.from_codex(%{
        "total" => %{
          "inputTokens" => 10,
          "outputTokens" => 2,
          "totalTokens" => 0,
          "cachedInputTokens" => 99
        },
        "last" => %{"inputTokens" => 0, "cachedInputTokens" => 99}
      })

    assert usage.total_tokens == 0
    assert usage.last_input_tokens == 0
    assert usage.cached_input_tokens == 10
    assert usage.last_cached_input_tokens == 0
    assert usage.requests == 0
  end
end
