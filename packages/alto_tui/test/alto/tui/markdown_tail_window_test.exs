defmodule Alto.TUI.MarkdownTailWindowTest do
  use ExUnit.Case, async: true

  alias Alto.TUI.Markdown

  test "scroll windows cross cached page boundaries without losing native styles or rows" do
    sources = [
      "```elixir\n" <>
        Enum.map_join(1..260, "\n", &"  IO.puts(\"line #{&1} 猫 with evidence\")") <> "\n```",
      String.duplicate("A **bold** finding and `code` 猫. ", 350)
    ]

    for source <- sources, width <- [17, 84] do
      full = Markdown.render(source, width).lines
      plan = Markdown.layout(source, width)

      for offset <- [0, 1, 61, 63, 64, 65, 126, plan.rows - 5, 64, 0], height <- [1, 9, 130] do
        assert Markdown.window(plan, offset, height) == Enum.slice(full, offset, height)
      end
    end
  end

  test "long prose, code, headings, and table records keep exact styled tail rows" do
    sources = [
      "A **bold** `token` and 猫. " <> String.duplicate("wrapped words 猫 ", 600),
      "```elixir\n" <> String.duplicate("  IO.puts(\"猫\")\n", 600) <> "```",
      "## **Heading** 猫 " <> String.duplicate("long heading ", 750),
      "| Name | Evidence |\n| --- | --- |\n| 猫 | " <>
        String.duplicate("**strong** `code` 猫 ", 450) <> " |\n| final | last record |"
    ]

    for source <- sources, width <- [17, 84] do
      full = Markdown.render(source, width)

      for height <- [1, 7, 40] do
        assert Markdown.tail(source, width, height).lines == Enum.take(full.lines, -height)
      end
    end
  end

  test "a long earlier block keeps its separator and visible rows before a short final block" do
    source =
      "## Earlier\n\n" <>
        String.duplicate("earlier **styled** 猫 ", 500) <>
        "\n\n```text\n  final\n```"

    for width <- [14, 70] do
      full = Markdown.render(source, width)

      for height <- [1, 8, 30] do
        assert Markdown.tail(source, width, height).lines == Enum.take(full.lines, -height)
      end
    end
  end

  test "small blocks retain the cached rendering path" do
    source =
      "## Short\n\nA **bold** `token` and 猫.\n\n| Name | Value |\n| --- | --- |\n| 猫 | yes |"

    for width <- [12, 80] do
      full = Markdown.render(source, width)

      for height <- [1, 6, 20] do
        assert Markdown.tail(source, width, height).lines == Enum.take(full.lines, -height)
      end
    end
  end

  test "repeated long tails reuse an identical styled result after another document" do
    source = "## Report\n\n" <> String.duplicate("**evidence** 猫 `code` ", 500)
    expected = Markdown.render(source, 37).lines |> Enum.take(-9)

    assert Markdown.tail(source, 37, 9).lines == expected
    Markdown.tail(String.duplicate("different long content ", 500), 37, 9)
    assert Markdown.tail(source, 37, 9).lines == expected
  end
end
