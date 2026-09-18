defmodule Alto.TUI.ApprovalViewTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.ApprovalView

  test "commands show prepared argv and folder, not Elixir arguments" do
    request = %{
      tool: "run_command",
      arguments: %{"program" => "echo", "args" => ["unprepared"]},
      details: %{
        command: %{
          requested_program: "ls",
          executable: "/usr/bin/ls",
          args: ["-la", "folder with spaces", "a'b"],
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
    text =
      ApprovalView.text(%{
        tool: "edit_file",
        arguments: %{"old_text" => "old", "new_text" => "new"},
        details: %{
          path: "hello.c",
          replacements: 1,
          bytes_before: 20,
          bytes_after: 30,
          preview: "new content"
        }
      })

    assert text =~ "Edit file\n\nFile\nhello.c"
    assert text =~ "Find\nold"
    assert text =~ "Replace with\nnew"
    assert text =~ "Preview\nnew content"
    refute text =~ "%{"
  end

  test "unknown tools retain nested details with readable labels and visible control characters" do
    text =
      ApprovalView.text(%{
        tool: "publish_report",
        arguments: %{"report_name" => "one"},
        details: %{access: %{writable_paths: ["/tmp"], network: :disabled}, note: "text\e[2J"}
      })

    assert text =~ "Publish report"
    assert text =~ "Writable paths: • /tmp"
    assert text =~ "Network: disabled"
    assert text =~ "\\u001b[2J"
    refute text =~ "\e"
    refute text =~ "%{"
  end
end
