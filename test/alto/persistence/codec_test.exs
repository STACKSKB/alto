defmodule Alto.Persistence.CodecTest do
  use ExUnit.Case, async: true

  alias Alto.Persistence.Codec

  test "requires complete ETF consumption" do
    encoded =
      :ok
      |> :erlang.term_to_binary()
      |> Kernel.<>(<<0>>)
      |> Base.encode64()

    assert {:error, :invalid_data} = Codec.decode(encoded)
  end

  test "rejects runtime capabilities" do
    port = Port.open({:spawn, "cat"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    for value <- [self(), make_ref(), fn -> :ok end, port] do
      refute Codec.valid?(value)
      assert {:error, :not_portable_or_too_large} = Codec.encode(value)
    end
  end

  test "enforces depth and encoded size bounds" do
    deep = Enum.reduce(1..65, :leaf, fn _, value -> [value] end)
    refute Codec.valid?(deep)
    assert {:error, :not_portable_or_too_large} = Codec.encode(deep)

    assert {:error, :not_portable_or_too_large} =
             Codec.encode(String.duplicate("x", 100), max_bytes: 10)
  end

  test "validates exact uncompressed bounds for native data without encoding" do
    for term <- [nil, :ok, %{atom: {:ok, [1, 2.5, "é"]}}, <<0, 255>>, MapSet.new([:a, :b])] do
      limit = :erlang.external_size(term)
      assert Codec.valid?(term, max_bytes: limit)
      assert {:ok, encoded} = Codec.encode(term, max_bytes: limit)
      assert {:ok, ^term} = Codec.decode(encoded, max_bytes: limit)
      refute Codec.valid?(term, max_bytes: limit - 1)
    end
  end
end
