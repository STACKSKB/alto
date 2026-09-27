defmodule Alto.TUI.ApprovalViewTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.ApprovalView

  test "commands show prepared argv and folder, not Elixir arguments" do
    request = %{
      id: "command",
      run_id: nil,
      call_id: nil,
      execution_mode: :exclusive,
      tool: "run_command",
      arguments: %{"program" => "echo", "args" => ["unprepared"]},
      details: %{
        command: %{
          requested_program: "ls",
          executable: "/usr/bin/ls",
          args: ["-la", "folder with spaces", "a'b", "sk-visible-argument", "control\e[2J"],
          cwd: "/projects/hello",
          timeout_ms: 30_000,
          max_output_bytes: 64_000
        },
        execution: %{backend: :unsandboxed, isolation: :none}
      }
    }

    text = ApprovalView.text(request)
    assert text =~ "Run command\n\nls -la 'folder with spaces' 'a'\\''b'"
    assert text =~ "Folder\n/projects/hello"
    assert text =~ "Executable\n/usr/bin/ls"
    assert text =~ "30 seconds"
    assert text =~ "64000 bytes"
    assert text =~ "without a sandbox"
    refute text =~ "unprepared"
    assert text =~ "sk-visible-argument 'control\\u001b[2J'"
    refute text =~ "\e"
    refute text =~ "%{"
    refute text =~ "=>"
  end

  test "remote command strings retain shell meaning and reasons" do
    request = %{
      "tool" => "Codex command",
      "arguments" => %{
        "command" => "ls -l && pwd",
        "cwd" => "/tmp",
        "reason" => "Inspect the project"
      },
      "details" => %{}
    }

    text = ApprovalView.text(request)
    assert text =~ "Run command\n\nls -l && pwd"
    assert text =~ "Reason\nInspect the project"
  end

  test "file changes have readable sizes, replacement text and preview" do
    preview = String.duplicate("line of content\n", 1_000) <> "FINAL PREVIEW LINE"

    text =
      ApprovalView.text(%{
        tool: "edit_file",
        arguments: %{"edits" => [%{"old_text" => "old", "new_text" => "new"}]},
        details: %{
          path: "hello.c",
          replacements: 1,
          bytes_before: 20,
          bytes_after: 30,
          preview: preview
        }
      })

    assert text =~ "Edit file\n\nFile\nhello.c"
    assert text =~ "Find\nold"
    assert text =~ "Replace with\nnew"
    assert text =~ "Preview\n" <> preview
    refute text =~ "%{"
  end

  test "prepared write previews display actual file lines instead of JSON wrappers" do
    root = temporary_workspace()
    content = "  first line\nsecond \"quoted\" line\n猫\n"
    args = %{"path" => "hello.txt", "content" => content}

    assert {:ok, prepared, details} =
             Alto.Tools.WriteFile.prepare(args, %{cwd: root}, Alto.Tools.WriteFile.options())

    assert details.preview == %{content: content, truncated: false}
    assert prepared.content == content
    refute File.exists?(Path.join(root, "hello.txt"))

    text = ApprovalView.text(%{tool: "write_file", arguments: args, details: details})
    assert text =~ "Write file\n\nFile\nhello.txt"
    assert text =~ "Size before\n0 bytes"
    assert text =~ "Size after\n#{byte_size(content)} bytes"
    assert text =~ "Preview\n" <> content
    refute text =~ ~s({"content":)
    refute text =~ ~s("truncated")
    refute text =~ "\\n"
    refute text =~ "Preview truncated"

    terminal = ExRatatui.init_test_terminal(80, 30)

    assert :ok =
             ExRatatui.draw(terminal, [
               {%ExRatatui.Widgets.Paragraph{text: text},
                %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 30}}
             ])

    lines =
      ExRatatui.get_buffer_content(terminal)
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    preview_row = Enum.find_index(lines, &(&1 == "Preview"))

    assert Enum.slice(lines, preview_row + 1, 3) == [
             "  first line",
             "second \"quoted\" line",
             "猫"
           ]
  end

  test "prepared write previews explain bounded content without displaying omitted bytes" do
    root = temporary_workspace()
    content = String.duplicate("猫\n", 1_100) <> "OMITTED TAIL"
    args = %{"path" => "large.txt", "content" => content}

    assert {:ok, _, details} =
             Alto.Tools.WriteFile.prepare(args, %{cwd: root}, Alto.Tools.WriteFile.options())

    assert details.preview.truncated
    assert String.valid?(details.preview.content)

    text = ApprovalView.text(%{tool: "write_file", arguments: args, details: details})
    assert text =~ "Preview\n" <> details.preview.content

    assert text =~
             "[Preview truncated; showing the first #{byte_size(details.preview.content)} bytes.]"

    assert text =~ "Size after\n#{byte_size(content)} bytes"
    refute text =~ "OMITTED TAIL"
    refute text =~ ~s({"content":)
  end

  test "prepared edits retain replacement details and render the resulting preview as text" do
    root = temporary_workspace()
    original = "old line\nold line\n"
    File.write!(Path.join(root, "edit.txt"), original)

    args = %{
      "path" => "edit.txt",
      "edits" => [
        %{"old_text" => "old line", "new_text" => "new line\nextra", "replace_all" => true}
      ]
    }

    opts = Map.put(Alto.Tools.EditFile.options(), :preview_bytes, 12)
    assert {:ok, prepared, details} = Alto.Tools.EditFile.prepare(args, %{cwd: root}, opts)
    assert details.replacements == 2
    assert details.preview.truncated
    assert File.read!(Path.join(root, "edit.txt")) == original

    text = ApprovalView.text(%{tool: "edit_file", arguments: args, details: details})
    assert text =~ "File\nedit.txt"
    assert text =~ "Size before\n#{byte_size(original)} bytes"
    assert text =~ "Size after\n#{byte_size(prepared.content)} bytes"
    assert text =~ "Replacements\n2"
    assert text =~ "Find\nold line"
    assert text =~ "Replace with\nnew line\nextra"
    assert text =~ "Preview\nnew line\next"
    assert text =~ "[Preview truncated; showing the first 12 bytes.]"
    refute text =~ ~s({"content":)
  end

  test "unknown tools retain complete nested details and visible control characters" do
    text =
      ApprovalView.text(%{
        tool: "publish_report",
        arguments: %{"report_name" => "one"},
        details: %{
          access: %{writable_paths: ["/tmp"], network: :disabled},
          note: "text\e[2J",
          entries: Enum.to_list(1..50),
          tuple: {:port, 123}
        }
      })

    assert text =~ "Publish report"

    sections =
      text
      |> String.split("\n\n")
      |> tl()
      |> Map.new(fn section ->
        [label, value] = String.split(section, "\n", parts: 2)
        {label, value}
      end)

    assert JSON.decode!(sections["Access"]) == %{
             "writable_paths" => ["/tmp"],
             "network" => "disabled"
           }

    assert JSON.decode!(sections["Entries"]) == Enum.to_list(1..50)
    assert JSON.decode!(sections["Tuple"]) == %{"$tuple" => ["port", 123]}
    assert sections["Note"] == "text\\u001b[2J"
    refute text =~ "\e"
    refute text =~ "%{"
  end

  defp temporary_workspace do
    root =
      Path.join(System.tmp_dir!(), "alto-approval-preview-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
