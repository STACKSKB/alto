defmodule Alto.RetainedTest do
  use ExUnit.Case, async: true

  test "detaches disproportionate backing binaries, including nested keys and values" do
    large = :binary.copy("a", 1_000_000)
    small = binary_part(large, 0, 180)
    assert :binary.referenced_byte_size(small) == 1_000_000

    %{title: copied, nested: [{key, value}]} =
      Alto.Retained.detach(%{title: small, nested: [{small, large}]})

    assert copied == small
    assert :binary.referenced_byte_size(copied) == 180
    assert :binary.referenced_byte_size(key) == 180
    assert value == large
  end
end
