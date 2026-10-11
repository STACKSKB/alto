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
  end

  test "effect traversal stops a lazy source before enumerating later operations" do
    source =
      Stream.map(1..4, fn item ->
        send(self(), {:enumerated, item})
        item
      end)

    assert {:error, :stopped} =
             Alto.Result.each(source, fn item ->
               send(self(), {:visited, item})
               if item == 3, do: {:error, :stopped}, else: :ok
             end)

    for item <- 1..3 do
      assert_received {:enumerated, ^item}
      assert_received {:visited, ^item}
    end

    refute_received {:enumerated, 4}
    refute_received {:visited, 4}
  end
end
