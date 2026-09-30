defmodule Alto.Contrib.Tools.FileResultRetentionTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Tools.ReadFile
  alias Alto.Contrib.Tools.SearchFiles

  setup do
    root =
      Path.join(System.tmp_dir!(), "alto-retained-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: %{cwd: root}}
  end

  test "UTF-8 line slices and exact byte limits release the scan buffer", %{
    root: root,
    context: context
  } do
    first_line = String.duplicate("a", 120) <> "\n"
    File.write!(Path.join(root, "source"), first_line <> String.duplicate("z", 999_879))

    assert {:ok, %{content: line, range_unit: "lines", returned_bytes: 121, truncated: true}} =
             Alto.Tool.run(
               ReadFile,
               %{"path" => "source", "start_line" => 1, "line_count" => 1},
               context
             )

    assert line == first_line
    assert :binary.referenced_byte_size(line) == byte_size(line)

    File.write!(Path.join(root, "exact"), String.duplicate("q", 100_000))

    assert {:ok, %{content: bytes, truncated: true, next_offset: 100}} =
             Alto.Tool.run(ReadFile, %{"path" => "exact", "limit" => 100}, context)

    assert bytes == String.duplicate("q", 100)
    assert :binary.referenced_byte_size(bytes) <= 101
  end

  test "invalid UTF-8 remains base64 encoded with unchanged byte metadata", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "binary"), <<255, 0, 1, 2>> <> :binary.copy(<<7>>, 100_000))

    assert {:ok,
            %{
              content_base64: "/wAB",
              encoding: "base64",
              offset: 0,
              next_offset: 3,
              truncated: true
            }} =
             Alto.Tool.run(ReadFile, %{"path" => "binary", "limit" => 3}, context)
  end

  test "untruncated multiline search snippets are detached while line numbering stays stable", %{
    root: root,
    context: context
  } do
    File.write!(
      Path.join(root, "matches"),
      "first\n" <>
        "prefix needle " <>
        String.duplicate("x", 90) <>
        "\n" <>
        String.duplicate("z", 999_000) <> "\nlast\n"
    )

    assert {:ok, %{matches: [match], scanned_files: 1, truncated: false, query: "needle"}} =
             Alto.Tool.run(
               SearchFiles,
               %{"query" => "needle", "path" => ".", "case_sensitive" => true},
               context,
               max_line_graphemes: 300
             )

    assert match.path == "matches"
    assert match.line == 2
    assert match.text == "prefix needle " <> String.duplicate("x", 90)
    assert :binary.referenced_byte_size(match.text) == byte_size(match.text)
  end
end
