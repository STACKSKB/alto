defmodule Alto.TUI.ActivityTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Activity

  test "retry activity explains the wait for parent and child events" do
    for type <- [:model_retry, "model_retry"] do
      assert Activity.phase(%{type: type, data: %{delay_ms: 1501}}) ==
               "waiting 2s before provider retry"
    end

    assert Activity.phase(%{type: :model_retry, data: %{}}) == "retrying provider connection"
    assert Activity.phase(%{type: :model_started, data: %{}}) == "waiting for model"
  end
end
