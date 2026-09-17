defmodule Alto.TextTest do
  use ExUnit.Case, async: true

  test "every byte budget preserves UTF-8 and includes the marker in the limit" do
    for value <- ["é🙂日本語", "áb́ć", "plain"], limit <- 0..30 do
      for result <- [Alto.Text.prefix(value, limit), Alto.Text.truncate(value, limit, "…")] do
        assert String.valid?(result)
        assert byte_size(result) <= limit
      end
    end

    assert Alto.Text.truncate("hello", 4, "...") == "h..."
  end
end
