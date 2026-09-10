defmodule Alto.Context.WindowTest do
  use ExUnit.Case, async: true

  alias Alto.Context.Window

  test "caps the requested window at the model limit and reserves output" do
    policy = Alto.Context.window(max_tokens: 200_000, reserve_output: 16_000)

    assert Window.resolve(policy, 128_000) == %{
             context_window: 128_000,
             input_tokens: 112_000,
             reserve_output: 16_000
           }
  end

  test "uses a lower user cap when the model supports more" do
    policy = Alto.Context.window(max_tokens: 200_000, reserve_output: 16_000)

    assert Window.resolve(policy, 1_000_000).context_window == 200_000
  end
end
