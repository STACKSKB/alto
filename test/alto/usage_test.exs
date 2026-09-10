defmodule Alto.UsageTest do
  use ExUnit.Case, async: true

  alias Alto.Usage

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
end
