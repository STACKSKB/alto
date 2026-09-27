defmodule Alto.ToolDisplayTest do
  use ExUnit.Case, async: true
  alias Alto.ToolDisplay

  test "false native results survive both local and wire event shapes" do
    for data <- [%{value: false}, %{"value" => false}] do
      assert ToolDisplay.entry(:tool_completed, data).detail == "No"
    end
  end

  test "tool titles identify files, commands and revisions without argument dumps" do
    assert ToolDisplay.summary("read_file", ~s({"path":"lib/a.ex","offset":20})) ==
             "read_file lib/a.ex (byte 20)"

    assert ToolDisplay.summary("git_inspect", %{"action" => "show", "ref" => "HEAD"}) ==
             "git show HEAD"

    assert ToolDisplay.summary("run_command", %{"program" => "ls", "args" => ["-la", "src"]}) ==
             ~s(argv: ls ["-la","src"])

    assert ToolDisplay.summary("run_command", %{
             "program" => "cat",
             "args" => ["file name.txt"]
           }) == ~s(argv: cat ["file name.txt"])

    assert ToolDisplay.summary("read_file", %{
             "path" => "lib/a.ex",
             "start_line" => 20,
             "line_count" => 10
           }) == "read_file lib/a.ex (lines 20–29)"

    refute ToolDisplay.summary("custom", %{"api_key" => "secret"}) =~ "secret"
  end

  test "command failures and timeouts are visible in live and restored results" do
    for name <- ["run_command", "run_shell"] do
      failed = %{exit_status: 7, output: "failed assertion", timed_out: false}

      for value <- [failed, JSON.encode!(failed)] do
        entry = ToolDisplay.entry(:tool_completed, %{name: name, value: value})
        assert entry.kind == :error
        assert entry.text =~ "failed (exit 7)"
        assert entry.detail == "failed assertion"
        refute entry.text =~ "✓"
      end

      entry =
        ToolDisplay.entry(:tool_completed, %{
          name: name,
          value: %{exit_status: 0, timed_out: true}
        })

      assert entry.kind == :error
      assert entry.text =~ "timed out"

      [restored] =
        ToolDisplay.transcript([
          %{"role" => "tool", "name" => name, "content" => JSON.encode!(failed)}
        ])

      assert restored.kind == :error
      assert restored.text =~ "failed (exit 7)"

      assert ToolDisplay.entry(:tool_completed, %{name: name, value: %{exit_status: 0}}).kind ==
               :tool
    end
  end

  test "shell summaries identify and bound the script" do
    assert ToolDisplay.summary("run_shell", %{"command" => "make test | tail -20"}) ==
             "shell: make test | tail -20"

    assert String.length(
             ToolDisplay.summary("run_shell", %{"command" => String.duplicate("x", 2000)})
           ) <= 500
  end

  test "edit and write results contain actual unified diffs and render real newlines" do
    root = Path.join(System.tmp_dir!(), "alto-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "a.txt"), "before\n")
    context = %{cwd: root, session_id: "diff-test"}

    assert {:ok, result} =
             run_tool(
               Alto.Tools.EditFile,
               %{
                 "path" => "a.txt",
                 "edits" => [%{"old_text" => "before", "new_text" => "after"}]
               },
               context
             )

    detail = ToolDisplay.detail(JSON.encode!(result))
    assert detail =~ "--- a/a.txt\n+++ b/a.txt"
    assert detail =~ "-before\n+after"
    refute detail =~ "\\n"

    assert {:ok, result} =
             run_tool(
               Alto.Tools.WriteFile,
               %{"path" => "a.txt", "content" => "replaced\n"},
               context
             )

    assert ToolDisplay.detail(result) =~ "-after\n+replaced"

    assert {:ok, result} =
             run_tool(Alto.Tools.WriteFile, %{"path" => "new.txt", "content" => "new\n"}, context)

    assert ToolDisplay.detail(result) =~ "+new"
  end

  defp run_tool(tool, arguments, context) do
    with {:ok, prepared, _details} <- Alto.Tool.prepare(tool, arguments, context, []),
         do: tool.run(prepared, context, [])
  end

  test "restored history pairs parallel tool results with their own filenames" do
    messages = [
      %{
        "role" => "assistant",
        "tool_calls" =>
          Enum.map(["a", "b"], fn id ->
            %{
              "id" => id,
              "function" => %{"name" => "read_file", "arguments" => JSON.encode!(%{path: id})}
            }
          end)
      },
      %{
        "role" => "tool",
        "tool_call_id" => "b",
        "content" => ~s({"content":"line one\\nline two"})
      },
      %{"role" => "tool", "tool_call_id" => "a", "content" => "ok"}
    ]

    assert [%{text: "read_file b ✓", detail: detail}, %{text: "read_file a ✓"}] =
             ToolDisplay.transcript(messages)

    assert detail == "17 bytes read"
  end

  test "live file reads show metadata without copying file contents into the terminal" do
    content = "PRIVATE_CANARY\n" <> String.duplicate("source line\n", 1000)
    value = %{path: "large.ex", content: content, offset: 0, truncated: true}

    entry =
      ToolDisplay.entry(:tool_completed, %{
        name: "read_file",
        arguments: %{path: "large.ex"},
        value: value
      })

    assert entry.text == "read_file large.ex ✓"
    assert entry.detail == "#{byte_size(content)} bytes read · more available"
    refute inspect(entry) =~ "PRIVATE_CANARY"
  end

  defmodule Provider do
    def describe(_), do: %{}

    def stream(request, _, _) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")),
        do: {:ok, %{message: "done", tool_calls: []}},
        else:
          {:ok,
           %{
             message: nil,
             tool_calls: [
               %{id: "read", name: "read_file", arguments_json: ~s({"path":"mix.exs"})}
             ]
           }}
    end
  end

  test "host presenters and absent presentation use the same execution path" do
    for {presenter, expected} <- [
          {nil, "read_file"},
          {fn name, _arguments -> "custom " <> name end, "custom read_file"}
        ] do
      assert %Alto.Runner.Result{status: :ok} =
               result =
               Alto.run("read",
                 provider: {Provider, []},
                 tools: [Alto.Tools.ReadFile],
                 tool_presenter: presenter
               )

      assert Enum.any?(
               result.events,
               &(&1.type == :tool_completed and &1.data.summary == expected)
             )
    end
  end

  test "serial and parallel execution retain informative titles in live and durable events" do
    for execution <- [:serial, {:parallel, 2}] do
      owner = self()

      assert %Alto.Runner.Result{status: :ok} =
               result =
               Alto.run("read",
                 tool_presenter: &Alto.ToolDisplay.summary/2,
                 provider: {Provider, []},
                 tools: [Alto.Tools.ReadFile],
                 loop: Alto.default_loop(tool_execution: execution),
                 event_sink: fn event -> send(owner, {:tool_display_event, event}) end
               )

      assert_received {:tool_display_event,
                       %Alto.Event{type: :tool_started, data: %{summary: "read_file mix.exs"}}}

      assert Enum.any?(
               result.events,
               &(&1.type == :tool_completed and &1.data.summary == "read_file mix.exs")
             )
    end
  end
end
