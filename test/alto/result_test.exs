defmodule Alto.ResultTest do
  use ExUnit.Case, async: true

  test "traversal preserves order and stops effects at the first error" do
    result =
      Alto.Result.traverse(1..4, fn item ->
        send(self(), {:visited, item})
        if item == 3, do: {:error, :stopped}, else: {:ok, item * 2}
      end)

    assert result == {:error, :stopped}
    assert_receive {:visited, 1}
    assert_receive {:visited, 2}
    assert_receive {:visited, 3}
    refute_received {:visited, 4}
    assert Alto.Result.traverse(1..3, &{:ok, &1 * 2}) == {:ok, [2, 4, 6]}

    assert Alto.Result.traverse([], fn _ -> flunk("empty traversal invoked callback") end) ==
             {:ok, []}
  end
end
