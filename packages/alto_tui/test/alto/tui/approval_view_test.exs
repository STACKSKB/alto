defmodule Alto.TUI.ApprovalViewTest do
  use ExUnit.Case, async: true
  alias Alto.TUI.ApprovalView

  test "commands show prepared argv and folder, not Elixir arguments" do
    request = %Alto.Approval.Request{
      id: "command",
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
end
