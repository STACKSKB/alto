defmodule Alto.PromptTest do
  use ExUnit.Case, async: true

  alias Alto.Tools.EditFile
  alias Alto.Tools.ListFiles
  alias Alto.Tools.RunCommand

  defmodule AnswerProvider do
    @behaviour Alto.Provider

    @impl true
    def describe(_opts), do: %{}

    @impl true
    def stream(request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:request, request})
      {:ok, %{message: "hello", tool_calls: []}}
    end
  end

  test "describes capabilities from the actual tool registry" do
    prompt = Alto.Prompt.coding_agent("/workspace", tools: [ListFiles])

    assert prompt =~ "read-only"
    assert prompt =~ "Command execution is disabled"
    refute prompt =~ "edit_file"

    no_tools = Alto.Prompt.coding_agent("/workspace", tools: [])
    assert no_tools =~ "No workspace tools are available"

    writable = Alto.Prompt.coding_agent("/workspace", tools: [ListFiles, EditFile, RunCommand])
    assert writable =~ "Workspace editing tools are enabled"
    assert writable =~ "command executor configured by the harness"

    command_only = Alto.Prompt.coding_agent("/workspace", tools: [RunCommand])
    refute command_only =~ "read-only"
    assert command_only =~ "command executor configured by the harness"
  end

  test "the default CLI read-only tool set renders the read-only guidance" do
    alias Alto.Tools.ReadFile
    alias Alto.Tools.SearchFiles

    prompt = Alto.Prompt.coding_agent("/workspace", tools: [ListFiles, ReadFile, SearchFiles])

    assert prompt =~ "This run is read-only"
    assert prompt =~ "Command execution is disabled"
  end

  test "chat and coding builders share the same runtime prompt boundary" do
    assert {:ok, result} =
             Alto.run("say hello",
               loop: Alto.chat_loop(),
               prompt: {Alto.Prompts.Chat, identity: "Be pleasantly concise."},
               provider: {AnswerProvider, test_pid: self()}
             )

    assert result.output == "hello"

    assert_receive {:request,
                    %{
                      messages: [
                        %{"role" => "system", "content" => prompt},
                        %{"role" => "user", "content" => "say hello"}
                      ]
                    }}

    assert prompt =~ "Be pleasantly concise."
    assert prompt =~ "no external tools"
  end

  test "renders bounded project instructions as a fragment" do
    instructions = %{
      path: "/workspace/alto.md",
      file: "alto.md",
      instructions: "Always run the test suite after edits.",
      truncated: false
    }

    assert {:ok, prompt} =
             Alto.Prompt.build(Alto.Prompts.Coding, %{
               cwd: "/workspace",
               tools: [],
               project_instructions: instructions
             })

    assert prompt =~ "project instructions (alto.md)"
    assert prompt =~ "Always run the test suite after edits."
  end

  test "marks truncated project instructions" do
    instructions = %{
      path: "/workspace/AGENTS.md",
      file: "AGENTS.md",
      instructions: "partial",
      truncated: true
    }

    assert {:ok, prompt} =
             Alto.Prompt.build(Alto.Prompts.Coding, %{
               cwd: "/workspace",
               tools: [],
               project_instructions: instructions
             })

    assert prompt =~ "project instructions truncated"
  end

  test "accepts a prompt function and rejects ambiguous configuration" do
    assert {:ok, "cwd=/tmp\n"} =
             Alto.Prompt.build(fn context -> "cwd=#{context.cwd}\n" end, %{
               cwd: "/tmp",
               tools: []
             })

    assert {:error, :conflicting_prompt_options, _result} =
             Alto.run("hello",
               provider: AnswerProvider,
               prompt: Alto.Prompts.Chat,
               system_prompt: "other"
             )
  end
end
