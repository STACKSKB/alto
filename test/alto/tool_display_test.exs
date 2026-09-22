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
             "read_file lib/a.ex (from 20)"

    assert ToolDisplay.summary("git_inspect", %{"action" => "show", "ref" => "HEAD"}) ==
             "git show HEAD"

    assert ToolDisplay.summary("run_command", %{"program" => "ls", "args" => ["-la", "src"]}) ==
             "ls -la src"

    refute ToolDisplay.summary("custom", %{"api_key" => "secret"}) =~ "secret"
  end

  test "edit and write results contain actual unified diffs and render real newlines" do
    root = Path.join(System.tmp_dir!(), "alto-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "a.txt"), "before\n")
    context = %Alto.Tool.Context{cwd: root, session_id: "diff-test"}

    assert {:ok, result} =
             Alto.Tools.EditFile.run(
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
             Alto.Tools.WriteFile.run(%{"path" => "a.txt", "content" => "replaced\n"}, context)

    assert ToolDisplay.detail(result) =~ "-after\n+replaced"

    assert {:ok, result} =
             Alto.Tools.WriteFile.run(%{"path" => "new.txt", "content" => "new\n"}, context)

    assert ToolDisplay.detail(result) =~ "+new"
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
    assert value.content == content
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

  defmodule Presenter do
    @behaviour Alto.ToolPresentation
    def summary(name, _arguments, options), do: Keyword.fetch!(options, :prefix) <> name
  end

  test "host presenters and absent presentation use the same execution path" do
    for {presenter, expected} <- [
          {nil, "read_file"},
          {{Presenter, prefix: "custom "}, "custom read_file"}
        ] do
      assert {:ok, result} =
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

      assert {:ok, result} =
               Alto.run("read",
                 tool_presenter: {Alto.ToolDisplay, []},
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
