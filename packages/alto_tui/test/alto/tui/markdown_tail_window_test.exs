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

  test "batched shared metrics preserve native rows and styles for plain, rich and Unicode blocks" do
    sources = [
      "## Answer 1",
      "Simple text",
      "1. list",
      "- list",
      "---",
      "## **Rich** 猫",
      "猫 é 👍",
      "```elixir\n  :ok  \n\n  :next\n\n```",
      "```text\n   \n\n```",
      "```text\n\n```",
      "```elixir\n\t:ok\n```",
      "## Answer 2\n\nShared **text**\n\n```elixir\n:ok\n```",
      "## Answer 3\n\nShared **text**\n\n```elixir\n:ok\n```"
    ]

    for width <- [6, 84] do
      plans = Markdown.layouts(sources, width)

      for source <- sources do
        full = Markdown.render(source, width).lines
        assert plans[source].rows == length(full)
        assert Markdown.window(plans[source], 0, 100) == full
      end
    end
  end
end
