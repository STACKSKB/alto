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

  test "reduction threads state in order and stops before later effects" do
    assert Alto.Result.reduce([], :initial, fn _, _ -> flunk("empty fold") end) == {:ok, :initial}

    assert Alto.Result.reduce(["a", "b"], "", fn item, acc -> {:ok, acc <> item} end) ==
             {:ok, "ab"}

    assert {:error, {:stopped, [2, 1]}} =
             Alto.Result.reduce(1..4, [], fn item, acc ->
               send(self(), {:visited, item, acc})
               if item == 3, do: {:error, {:stopped, acc}}, else: {:ok, [item | acc]}
             end)

    assert_receive {:visited, 1, []}
    assert_receive {:visited, 2, [1]}
    assert_receive {:visited, 3, [2, 1]}
    refute_received {:visited, 4, _}
  end
end
