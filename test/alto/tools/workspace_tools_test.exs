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

  defp prepared_run(tool, arguments, context, opts \\ []) do
    with {:ok, prepared, _details} <- tool.prepare(arguments, context, opts),
         do: tool.run(prepared, context, opts)
  end

  test "reads and writes only bounded workspace paths", %{root: root, context: context} do
    assert {:ok, %{bytes_written: 6}} =
             prepared_run(WriteFile, %{"path" => "sample.txt", "content" => "abcdef"}, context)

    assert {:ok, %{content: "bcd", truncated: true}} =
             ReadFile.run(%{"path" => "sample.txt", "offset" => 1, "limit" => 3}, context)

    for offset <- [6, 9] do
      assert {:ok, %{content: "", truncated: false}} =
               ReadFile.run(%{"path" => "sample.txt", "offset" => offset}, context)
    end

    assert File.read!(Path.join(root, "sample.txt")) == "abcdef"

    assert {:error, {:path_outside_workspace, "../outside.txt"}} =
             prepared_run(WriteFile, %{"path" => "../outside.txt", "content" => "no"}, context)
  end

  test "host-configured write limits apply during preparation and stay frozen", %{
    context: context
  } do
    assert {:error, {:content_too_large, 3}} =
             prepared_run(WriteFile, %{"path" => "too.txt", "content" => "1234"}, context,
               max_bytes: 3
             )

    assert {:ok, prepared, _details} =
             WriteFile.prepare(%{"path" => "ok.txt", "content" => "1234"}, context, max_bytes: 4)

    assert {:ok, %{bytes_written: 4}} = WriteFile.run(prepared, context, max_bytes: 1)

    assert {:error, {:invalid_write_options, _}} =
             prepared_run(WriteFile, %{}, context, max_bytes: 0)
  end

  test "host-configured edit limits bound files, replacements, and edit counts", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "edit.txt"), "abcdef")

    assert {:error, {:file_too_large, 3}} =
             prepared_run(
               EditFile,
               %{"path" => "edit.txt", "edits" => [%{"old_text" => "a", "new_text" => "b"}]},
               context,
               max_file_bytes: 3
             )

    assert {:error, {:replacement_too_large, 1}} =
             prepared_run(
               EditFile,
               %{"path" => "edit.txt", "edits" => [%{"old_text" => "a", "new_text" => "long"}]},
               context,
               max_replacement_bytes: 1
             )

    assert {:error, {:too_many_edits, 1}} =
             prepared_run(
               EditFile,
               %{
                 "path" => "edit.txt",
                 "edits" => [
                   %{"old_text" => "a", "new_text" => "b"},
                   %{"old_text" => "c", "new_text" => "d"}
                 ]
               },
               context,
               max_edits: 1
             )

    assert {:error, {:invalid_edit_options, _}} =
             prepared_run(EditFile, %{}, context, max_input_bytes: 0)
  end

  test "edit schema and runtime require the canonical edits list", %{context: context} do
    parameters = EditFile.schema().parameters
    assert parameters.required == ["path", "edits"]
    assert Map.keys(parameters.properties) |> Enum.sort() == [:edits, :path]

    assert {:error, :edits_must_be_nonempty_list} =
             prepared_run(
               EditFile,
               %{"path" => "edit.txt", "old_text" => "a", "new_text" => "b"},
               context
             )
  end

  test "host-configured search limits skip large files and bound line output", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "large.txt"), "needle\n" <> String.duplicate("x", 20))

    assert {:ok, %{matches: [], scanned_files: 0}} =
             SearchFiles.run(%{"query" => "needle"}, context, max_file_bytes: 3)

    assert {:ok, %{matches: [%{text: text}]}} =
             SearchFiles.run(%{"query" => "needle"}, context, max_line_graphemes: 3)

    assert text == "nee…"
  end

  test "host-configured search bounds cap traversal and result counts", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "a.txt"), "needle\nneedle\n")
    File.write!(Path.join(root, "b.txt"), "needle\n")

    assert {:ok, %{scanned_files: 1, truncated: true}} =
             SearchFiles.run(%{"query" => "needle"}, context, max_files: 1)

    assert {:ok, %{scanned_files: 0, truncated: true}} =
             SearchFiles.run(%{"query" => "needle"}, context, max_entries: 1)

    assert {:ok, %{matches: matches, truncated: true}} =
             SearchFiles.run(%{"query" => "needle"}, context, max_matches: 1)

    assert length(matches) == 1

    assert {:error, {:query_too_large, 2}} =
             SearchFiles.run(%{"query" => "long"}, context, max_query_bytes: 2)
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
             prepared_run(WriteFile, %{"path" => "chainedir/passwd", "content" => "no"}, context)
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

  test "search truncates long grapheme lines at the configured display bound", %{
    root: root,
    context: context
  } do
    line = String.duplicate("界", 400) <> " needle"
    File.write!(Path.join(root, "unicode.txt"), line)

    assert {:ok, %{matches: [%{text: text}]}} =
             SearchFiles.run(%{"path" => "unicode.txt", "query" => "needle"}, context)

    assert String.length(text) == 301
    assert String.ends_with?(text, "…")
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

    options = [backend: {SearchBackend, label: "index"}, max_query_bytes: 6]
    assert {:ok, _tools, [definition]} = Alto.Tool.Registry.build([{SearchFiles, options}])
    assert definition["function"]["parameters"][:properties][:query][:maxLength] == 6

    assert {:error, {:query_too_large, 6}} =
             SearchFiles.run(%{"query" => "too long"}, context, options)

    assert {:ok, run} =
             Alto.run(%{"query" => "needle"},
               loop: Alto.rule_loop(steps: ["search_files"]),
               tools: [{SearchFiles, options}],
               cwd: context.cwd
             )

    assert [%{matches: [%{path: "index"}]}] = run.output
  end

  test "search rejects invalid backends before invocation", %{context: context} do
    assert {:error, {:invalid_capability, Alto.Search.Backend, {String, []}}} =
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
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "one", "new_text" => "three"}]
               },
               context
             )

    assert File.read!(path) == "one two one\n"

    assert {:ok, %{replacements: 2}} =
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [
                   %{"old_text" => "one", "new_text" => "three", "replace_all" => true}
                 ]
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
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "before", "new_text" => "after"}]
               },
               context
             )

    assert details.preview == %{content: "after\n", truncated: false}
    File.write!(path, "changed by another writer\n")

    assert {:error, {:stale_file, "sample.txt"}} = EditFile.run(prepared, context)
    assert File.read!(path) == "changed by another writer\n"
  end

  test "prepared file changes reject mode changes and retargeted symlinks", %{
    root: root,
    context: context
  } do
    first = Path.join(root, "first.txt")
    second = Path.join(root, "second.txt")
    link = Path.join(root, "link.txt")
    File.write!(first, "before")
    File.write!(second, "before")
    File.chmod!(first, 0o640)
    File.ln_s!("first.txt", link)

    changes = [
      {WriteFile, %{"path" => "link.txt", "content" => "after"}},
      {EditFile,
       %{
         "path" => "link.txt",
         "edits" => [%{"old_text" => "before", "new_text" => "after"}]
       }}
    ]

    for {tool, arguments} <- changes do
      assert {:ok, prepared, _details} = tool.prepare(arguments, context)
      File.chmod!(first, 0o600)
      assert {:error, {:stale_file, _path}} = tool.run(prepared, context)
      File.chmod!(first, 0o640)

      File.rm!(link)
      File.ln_s!("second.txt", link)

      assert {:error, {:prepared_path_changed, "link.txt"}} =
               tool.run(prepared, context)

      assert File.read!(first) == "before"
      assert File.read!(second) == "before"

      File.rm!(link)
      File.ln_s!("first.txt", link)
    end
  end

  test "applies disjoint edits against one original snapshot", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "a b a\n")

    assert {:ok, %{replacements: 3, bytes_before: 6, bytes_after: 6}} =
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [
                   %{"old_text" => "a", "new_text" => "b", "replace_all" => true},
                   %{"old_text" => "b", "new_text" => "c"}
                 ]
               },
               context
             )

    # The second edit matches the original b, not the b produced by the first edit.
    assert File.read!(path) == "b c b\n"
  end

  test "bounds the final edit result after both growth and deletion", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "aXYZ")

    arguments = %{
      "path" => "sample.txt",
      "edits" => [
        %{"old_text" => "XYZ", "new_text" => ""},
        %{"old_text" => "a", "new_text" => "123456"}
      ]
    }

    assert {:error, {:file_too_large, 5}} =
             EditFile.prepare(arguments, context, max_file_bytes: 5)

    assert File.read!(path) == "aXYZ"

    assert {:ok, %{bytes_after: 6, replacements: 2}} =
             prepared_run(EditFile, arguments, context, max_file_bytes: 6)

    assert File.read!(path) == "123456"
  end

  test "rejects overlapping multi-edit requests without writing", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "abcdef\n")

    assert {:error, :overlapping_edits} =
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [
                   %{"old_text" => "abc", "new_text" => "x"},
                   %{"old_text" => "bcd", "new_text" => "y"}
                 ]
               },
               context
             )

    assert {:error, :text_not_found} =
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "abc def", "new_text" => "x"}]
               },
               context
             )

    assert File.read!(path) == "abcdef\n"
  end

  test "preserves BOM, CRLF line endings, and unrelated bytes", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    original = <<0xEF, 0xBB, 0xBF>> <> "one\r\ntwo\r\nthree\r\n"
    File.write!(path, original)

    assert {:ok, %{replacements: 1}} =
             prepared_run(
               EditFile,
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "two", "new_text" => "second"}]
               },
               context
             )

    assert File.read!(path) == <<0xEF, 0xBB, 0xBF>> <> "one\r\nsecond\r\nthree\r\n"
  end

  test "approval details contain a bounded unified patch from the frozen content", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "before")
    replacement = :binary.copy("é", 20_000)

    assert {:ok, _prepared, details} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "before", "new_text" => replacement}]
               },
               context
             )

    assert details.preview.truncated
    assert byte_size(details.preview.content) <= 4_096
    assert String.valid?(details.preview.content)
    assert details.patch.truncated
    assert byte_size(details.patch.content) <= 16_384
    assert String.valid?(details.patch.content)
    assert details.patch.content =~ "--- a/sample.txt\n+++ b/sample.txt\n"
    assert details.patch.content =~ "-before\n\\ No newline at end of file\n"
  end

  test "edit input, prepared output, and both snapshot reads are bounded", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "sample.txt")
    File.write!(path, "marker" <> :binary.copy("x", 800_000))

    oversized_edits =
      Enum.map(1..6, fn index ->
        %{
          "old_text" => "marker#{index}" <> :binary.copy("o", 200_000),
          "new_text" => "n"
        }
      end)

    assert {:error, {:edit_input_too_large, 1_256_000}} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" =>
                   oversized_edits ++
                     [%{"old_text" => :binary.copy("z", 56_000), "new_text" => "n"}]
               },
               context
             )

    assert {:error, {:replacement_too_large, 256_000}} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" => [
                   %{"old_text" => "marker", "new_text" => :binary.copy("n", 256_001)}
                 ]
               },
               context
             )

    assert {:error, {:file_too_large, 1_000_000}} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" => [
                   %{"old_text" => "marker", "new_text" => :binary.copy("n", 256_000 - 6)}
                 ]
               },
               context
             )

    File.write!(path, "before\n")

    assert {:ok, prepared, _details} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "before", "new_text" => "after"}]
               },
               context
             )

    File.write!(path, :binary.copy("z", 1_000_001))

    assert {:error, {:file_too_large, 1_000_000}} =
             EditFile.run(prepared, context)
  end

  test "prepared writes refuse a target created after approval", %{root: root, context: context} do
    assert {:ok, prepared, details} =
             WriteFile.prepare(%{"path" => "new.txt", "content" => "approved\n"}, context)

    assert details.preview == %{content: "approved\n", truncated: false}
    File.write!(Path.join(root, "new.txt"), "created by another writer\n")

    assert {:error, {:stale_file, path}} = WriteFile.run(prepared, context)
    assert path == Path.join(root, "new.txt")
    assert File.read!(path) == "created by another writer\n"
  end

  test "writes fingerprint large originals without retaining a diff", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "large.txt")
    original = "0123456789abcdef"
    File.write!(path, original)

    assert {:ok, prepared, details} =
             WriteFile.prepare(%{"path" => "large.txt", "content" => "small"}, context,
               max_bytes: 8
             )

    assert details.bytes_before == byte_size(original)
    assert details.patch == nil
    refute Map.has_key?(prepared.original, :content)

    File.write!(path, "0123456789abcdeg")
    assert {:error, {:stale_file, ^path}} = WriteFile.run(prepared, context)
    File.write!(path, original)
    assert {:ok, %{bytes_written: 5, patch: nil}} = WriteFile.run(prepared, context)
    assert File.read!(path) == "small"
  end

  test "write and edit approval diffs can be disabled", %{root: root, context: context} do
    path = Path.join(root, "sample.txt")
    File.write!(path, "before")

    assert {:ok, write, %{patch: nil}} =
             WriteFile.prepare(%{"path" => "sample.txt", "content" => "after"}, context,
               diff_bytes: 0
             )

    assert {:ok, %{patch: nil}} = WriteFile.run(write, context)

    assert {:ok, edit, %{patch: nil}} =
             EditFile.prepare(
               %{
                 "path" => "sample.txt",
                 "edits" => [%{"old_text" => "after", "new_text" => "done"}]
               },
               context,
               patch_bytes: 0
             )

    assert {:ok, %{patch: nil}} = EditFile.run(edit, context)
    assert File.read!(path) == "done"
  end

  test "write_file writes atomically and leaves no temp litter", %{
    root: root,
    context: context
  } do
    assert {:ok, %{bytes_written: 3}} =
             prepared_run(WriteFile, %{"path" => "a.txt", "content" => "abc"}, context)

    assert {:ok, ["a.txt"]} = File.ls(root)
  end

  test "write_file preserves an existing file's mode", %{root: root, context: context} do
    path = Path.join(root, "existing.txt")
    File.write!(path, "old")
    File.chmod!(path, 0o640)

    assert {:ok, %{bytes_written: 3}} =
             prepared_run(WriteFile, %{"path" => "existing.txt", "content" => "new"}, context)

    assert File.read!(path) == "new"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  test "write_file rejects content that is not valid UTF-8", %{context: context} do
    assert {:error, :content_is_not_utf8} =
             prepared_run(WriteFile, %{"path" => "x.bin", "content" => <<0xFF, 0xFE>>}, context)
  end
end
