defmodule Alto.Contrib.UsageTest do
  use ExUnit.Case, async: true
  alias Alto.Usage

  test "normalizes common token and cache fields" do
    openai =
      Alto.Contrib.Usage.normalize(%{
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
      Alto.Contrib.Usage.normalize(%{
        "input_tokens" => 400,
        "output_tokens" => 50,
        "cache_read_input_tokens" => 200
      })

    assert anthropic.input_tokens == 600
    assert Float.round(Usage.cache_hit_rate(anthropic), 1) == 33.3
    assert Usage.merge(openai, anthropic).total_tokens == 1_730
  end

  test "codex snapshots preserve zeros and do not claim a request count" do
    usage =
      Alto.Contrib.Usage.from_codex(%{
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

  test "context limits survive Codex normalization, serialization and additive updates" do
    usage =
      Alto.Contrib.Usage.from_codex(%{
        total: %{inputTokens: 100},
        last: %{inputTokens: 100},
        modelContextWindow: 200_000
      })

    assert usage.context_window == 200_000
    assert Alto.Contrib.Usage.normalize(usage).context_window == 200_000
    native = %{Usage.new() | requests: 1, last_input_tokens: 50, context_window: 100_000}
    merged = Usage.merge(native, usage)
    assert merged.last_input_tokens == 50
    assert merged.context_window == 100_000

    assert Usage.merge(native, Alto.Contrib.Usage.normalize(%{input_tokens: 25})).context_window ==
             nil
  end
end
