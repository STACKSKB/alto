defmodule Alto.TUI.ScrollTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.Scroll

  test "caps at the last wrapped row using native Unicode word wrapping" do
    assert Scroll.bottom("", 20, 5, :test) == 0
    assert Scroll.bottom("short", 20, 5, :test) == 0
    assert Scroll.bottom("one\ntwo\nthree\n\n", 20, 2, :test) == 1
    assert Scroll.bottom("猫猫猫猫猫猫", 4, 2, :test) == 1
    assert Scroll.bottom("one two three four", 5, 2, :test) == 2
    assert Scroll.bottom("one two three four", 30, 2, :test) == 0
    assert Scroll.bottom("start" <> String.duplicate("\n", 300) <> "end", 20, 2, :test) == 299
  end
end
