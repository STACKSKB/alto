defmodule Alto.TUI.CacheTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Cache

  test "aggregate weighted bytes stay bounded across namespaces and owners can be released" do
    Cache.owner("a")

    for n <- 1..20 do
      value = String.duplicate("#{n} ", 100_000)
      assert Cache.fetch({__MODULE__, n}, n, 4, fn -> value end) == value
      assert Cache.stats().bytes <= 16_000_000
    end

    Cache.owner("b")
    assert Cache.fetch({__MODULE__, :kept}, :key, 4, fn -> :kept end) == :kept
    Cache.drop_owner("a")
    assert map_size(Cache.stats().items) == 1
    assert Cache.fetch({__MODULE__, :kept}, :key, 4, fn -> flunk("cache lost") end) == :kept
    Cache.drop_namespace(__MODULE__)
    assert Cache.stats().bytes == 0
  end

  test "nested builds preserve children and oversized entries are not retained" do
    Cache.fetch({__MODULE__, :parent}, :key, 1, fn ->
      Cache.fetch({__MODULE__, :child}, :key, 1, fn -> "child" end)
    end)

    assert map_size(Cache.stats().items) == 2
    huge = String.duplicate("x", 6_000_000)
    assert Cache.fetch({__MODULE__, :huge}, :key, 1, fn -> huge end) == huge
    assert map_size(Cache.stats().items) == 2
  end

  test "lowering the configured budget evicts immediately and zero disables caching" do
    Cache.fetch({__MODULE__, :view}, :key, 1, fn -> "content" end)
    assert Cache.stats().bytes > 0
    Cache.configure(0)
    assert Cache.stats().bytes == 0
    assert Cache.fetch({__MODULE__, :view}, :key, 1, fn -> :uncached end) == :uncached
    assert Cache.stats().items == %{}
  end
end
