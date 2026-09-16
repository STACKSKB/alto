defmodule Alto.ToolDisplayTest do
  use ExUnit.Case, async: true
  alias Alto.ToolDisplay

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
               %{"path" => "a.txt", "old_text" => "before", "new_text" => "after"},
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

    assert detail =~ "line one\nline two"
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

  test "serial and parallel execution retain informative titles in live and durable events" do
    for execution <- [:serial, {:parallel, 2}] do
      owner = self()

      assert {:ok, result} =
               Alto.run("read",
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
