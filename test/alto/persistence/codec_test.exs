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
      assert {:error, :not_portable_or_too_large} = Codec.encode(value)
    end
  end

  test "enforces depth and encoded size bounds" do
    deep = Enum.reduce(1..65, :leaf, fn _, value -> [value] end)
    assert {:error, :not_portable_or_too_large} = Codec.encode(deep)

    assert {:error, :not_portable_or_too_large} =
             Codec.encode(String.duplicate("x", 100), max_bytes: 10)
  end
end
