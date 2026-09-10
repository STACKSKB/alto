defmodule Alto.Tools.WorkspaceToolsTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Context
  alias Alto.Tools.EditFile
  alias Alto.Tools.ListFiles
  alias Alto.Tools.ReadFile
  alias Alto.Tools.SearchFiles
  alias Alto.Tools.WriteFile

  defmodule SearchBackend do
    @behaviour Alto.Search.Backend

    @impl true
    def search(request, context, opts) do
      {:ok,
       %{
         matches: [
           %{
             path: Keyword.fetch!(opts, :label),
             line: 1,
             text: "#{request.query}@#{Path.basename(context.cwd)}"
           }
         ],
         scanned_files: 7,
         truncated: false
       }}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-tools-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: %Context{session_id: "test", cwd: root}}
  end

  test "reads and writes only bounded workspace paths", %{root: root, context: context} do
    assert {:ok, %{bytes_written: 6}} =
             WriteFile.run(%{"path" => "sample.txt", "content" => "abcdef"}, context)

    assert {:ok, %{content: "bcd", truncated: true}} =
             ReadFile.run(%{"path" => "sample.txt", "offset" => 1, "limit" => 3}, context)

    assert File.read!(Path.join(root, "sample.txt")) == "abcdef"

    assert {:error, {:path_outside_workspace, "../outside.txt"}} =
             WriteFile.run(%{"path" => "../outside.txt", "content" => "no"}, context)
  end

  test "read_file's maximum result stays within the runner's native bound", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "binary.dat"), :binary.copy(<<255>>, 47_000))

    assert {:ok, result} =
             ReadFile.run(%{"path" => "binary.dat", "limit" => 47_000}, context)

    assert result.encoding == "base64"
    assert :erlang.external_size(result) <= 64_000

    assert {:error, {:invalid_range, 0, 47_001}} =
             ReadFile.run(%{"path" => "binary.dat", "limit" => 47_001}, context)
  end

  test "rejects symlinks that escape the workspace through any path component", %{
    root: root,
    context: context
  } do
    File.ln_s!("/etc/passwd", Path.join(root, "escape"))

    assert {:error, {:path_outside_workspace, "escape"}} =
             ReadFile.run(%{"path" => "escape"}, context)

    # A symlinked parent directory is equally refused, including chains.
    outside = Path.join(System.tmp_dir!(), "alto-outside-#{System.unique_integer([:positive])}")
    File.mkdir!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.ln_s!(outside, Path.join(root, "linkdir"))
    File.ln_s!("linkdir", Path.join(root, "chainedir"))

    assert {:error, {:path_outside_workspace, "linkdir/passwd"}} =
             ReadFile.run(%{"path" => "linkdir/passwd"}, context)

    assert {:error, {:path_outside_workspace, "chainedir/passwd"}} =
             WriteFile.run(%{"path" => "chainedir/passwd", "content" => "no"}, context)
  end

  test "resolves an internal symlink to its confined target", %{root: root, context: context} do
    File.write!(Path.join(root, "real.txt"), "x")
    File.ln_s!("real.txt", Path.join(root, "internal"))

    assert {:ok, %{content: "x"}} = ReadFile.run(%{"path" => "internal"}, context)
  end

  test "lists one directory with entry types", %{root: root, context: context} do
    File.write!(Path.join(root, "a.txt"), "a")
    File.mkdir!(Path.join(root, "dir"))

    assert {:ok, %{entries: entries, truncated: false}} = ListFiles.run(%{}, context)
    assert entries == [%{name: "a.txt", type: :regular}, %{name: "dir", type: :directory}]
  end

  test "recursively searches text files without following symlinks or generated directories", %{
    root: root,
    context: context
  } do
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.mkdir_p!(Path.join(root, "node_modules/pkg"))
    File.write!(Path.join(root, "lib/a.ex"), "first needle\nsecond\n")
    File.write!(Path.join(root, "lib/nested/b.ex"), "Needle again\n")
    File.write!(Path.join(root, "node_modules/pkg/generated.js"), "needle\n")

    outside =
      Path.join(System.tmp_dir!(), "alto-search-outside-#{System.unique_integer([:positive])}")

    File.write!(outside, "needle\n")
    File.ln_s!(outside, Path.join(root, "linked.txt"))
    on_exit(fn -> File.rm(outside) end)

    assert {:ok, result} =
             SearchFiles.run(
               %{"query" => "needle", "case_sensitive" => false},
               context
             )

    assert result.truncated == false
    assert result.scanned_files == 2

    assert Enum.map(result.matches, &{&1.path, &1.line, &1.text}) == [
             {"lib/a.ex", 1, "first needle"},
             {"lib/nested/b.ex", 1, "Needle again"}
           ]
  end

  test "search is literal, bounded, and accepts a single file path", %{
    root: root,
    context: context
  } do
    lines = Enum.map_join(1..101, "\n", &"line #{&1}: .*")
    File.write!(Path.join(root, "sample.txt"), lines)

    assert {:ok, result} =
             SearchFiles.run(%{"path" => "sample.txt", "query" => ".*"}, context)

    assert length(result.matches) == 100
    assert result.truncated
    assert hd(result.matches) == %{path: "sample.txt", line: 1, text: "line 1: .*"}
  end

  test "search validates query and case options", %{context: context} do
    assert {:error, :query_must_be_nonempty} = SearchFiles.run(%{"query" => ""}, context)

    assert {:error, :case_sensitive_must_be_boolean} =
             SearchFiles.run(%{"query" => "x", "case_sensitive" => "no"}, context)
  end

  test "search backend is selected by configured tool options", %{context: context} do
    assert {:ok, result} =
             SearchFiles.run(
               %{"query" => "needle"},
               context,
               backend: {SearchBackend, label: "ripgrep"}
             )

    assert result.matches == [
             %{
               path: "ripgrep",
               line: 1,
               text: "needle@#{Path.basename(context.cwd)}"
             }
           ]

    assert result.scanned_files == 7
  end

  test "search rejects invalid backends before invocation", %{context: context} do
    assert {:error, {:invalid_search_backend, {String, []}}} =
             SearchFiles.run(%{"query" => "needle"}, context, backend: String)
  end

  test "edits one unique match atomically and preserves file mode", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "one two one\n")
    File.chmod!(path, 0o640)

    assert {:error, {:ambiguous_match, 2}} =
             EditFile.run(
               %{"path" => "sample.txt", "old_text" => "one", "new_text" => "three"},
               context
             )

    assert File.read!(path) == "one two one\n"

    assert {:ok, %{replacements: 2}} =
             EditFile.run(
               %{
                 "path" => "sample.txt",
                 "old_text" => "one",
                 "new_text" => "three",
                 "replace_all" => true
               },
               context
             )

    assert File.read!(path) == "three two three\n"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  test "prepared edits show the frozen result and refuse stale files", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "before\n")

    assert {:ok, prepared, details} =
             EditFile.prepare(
               %{"path" => "sample.txt", "old_text" => "before", "new_text" => "after"},
               context
             )

    assert details.preview == %{content: "after\n", truncated: false}
    File.write!(path, "changed by another writer\n")

    assert {:error, {:stale_file, "sample.txt"}} = EditFile.run_prepared(prepared, context)
    assert File.read!(path) == "changed by another writer\n"
  end

  test "prepared writes refuse a target created after approval", %{root: root, context: context} do
    assert {:ok, prepared, details} =
             WriteFile.prepare(%{"path" => "new.txt", "content" => "approved\n"}, context)

    assert details.preview == %{content: "approved\n", truncated: false}
    File.write!(Path.join(root, "new.txt"), "created by another writer\n")

    assert {:error, {:stale_file, path}} = WriteFile.run_prepared(prepared, context)
    assert path == Path.join(root, "new.txt")
    assert File.read!(path) == "created by another writer\n"
  end

  test "write_file writes atomically and leaves no temp litter", %{
    root: root,
    context: context
  } do
    assert {:ok, %{bytes_written: 3}} =
             WriteFile.run(%{"path" => "a.txt", "content" => "abc"}, context)

    assert {:ok, ["a.txt"]} = File.ls(root)
  end

  test "write_file preserves an existing file's mode", %{root: root, context: context} do
    path = Path.join(root, "existing.txt")
    File.write!(path, "old")
    File.chmod!(path, 0o640)

    assert {:ok, %{bytes_written: 3}} =
             WriteFile.run(%{"path" => "existing.txt", "content" => "new"}, context)

    assert File.read!(path) == "new"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  test "write_file rejects content that is not valid UTF-8", %{context: context} do
    assert {:error, :content_is_not_utf8} =
             WriteFile.run(%{"path" => "x.bin", "content" => <<0xFF, 0xFE>>}, context)
  end
end
