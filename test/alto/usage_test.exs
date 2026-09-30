defmodule Alto.UsageTest do
  use ExUnit.Case, async: true
  alias Alto.Usage

  test "latest cache rate is separate from cumulative cold-start costs" do
    cold = Alto.Usage.normalize(%{"input_tokens" => 1000})

    warm =
      Alto.Usage.normalize(%{
        "input_tokens" => 2000,
        "cached_input_tokens" => 1900
      })

    usage = Alto.Usage.merge(cold, warm)
    assert Alto.Usage.last_cache_hit_rate(usage) == 95.0
    assert Alto.Usage.cache_hit_rate(usage) < 64
  end

  test "preserves explicit zero fields while defaulting only missing fields" do
    assert Usage.normalize(%{"input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 0}).total_tokens ==
             0

    assert Usage.normalize(%{
             requests: 0,
             input_tokens: 12,
             total_tokens: 0,
             last_input_tokens: 0,
             cached_input_tokens: 99,
             last_cached_input_tokens: 99
           }) == %{
             input_tokens: 12,
             output_tokens: 0,
             total_tokens: 0,
             cached_input_tokens: 12,
             last_input_tokens: 0,
             last_cached_input_tokens: 0,
             requests: 0,
             context_window: nil
           }

    assert Usage.normalize(%{"input_tokens" => 12}).last_input_tokens == 12
  end
end
