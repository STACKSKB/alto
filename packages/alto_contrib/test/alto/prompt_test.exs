defmodule Alto.PromptTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Tools.EditFile
  alias Alto.Contrib.Tools.ListFiles
  alias Alto.Contrib.Tools.RunCommand

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

  defmodule NamedTool do
    def options, do: %{name: :read_file}
    def name(opts), do: opts.name
  end

  test "coding prompts use the configured name/1 tool contract" do
    assert Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: [NamedTool]}) =~
             "read-only"

    for opts <- [[name: :write_file], %{name: :write_file}] do
      assert Alto.Contrib.Prompts.Coding.build(%{
               cwd: "/workspace",
               tools: [{NamedTool, opts}]
             }) =~ "Workspace editing tools are enabled"
    end
  end

  test "describes capabilities from the actual tool registry" do
    prompt = Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: [ListFiles]})

    assert prompt =~ "read-only"
    assert prompt =~ "Command execution is disabled"
    refute prompt =~ "edit_file"

    no_tools = Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: []})
    assert no_tools =~ "No workspace tools are available"

    writable =
      Alto.Contrib.Prompts.Coding.build(%{
        cwd: "/workspace",
        tools: [ListFiles, EditFile, RunCommand]
      })

    assert writable =~ "Workspace editing tools are enabled"
    assert writable =~ "command executor configured by the harness"
    assert writable =~ ~s({"program":"./build/test","args":[]})
    assert writable =~ "pipefail"
    assert writable =~ "do not append tail or echo"
    assert writable =~ "timeout_ms` accepts 1..120000 and defaults to 30000"

    command_only = Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: [RunCommand]})
    refute command_only =~ "read-only"
    assert command_only =~ "command executor configured by the harness"
    refute command_only =~ "program=bash with args=[-lc"
  end

  test "shell guidance follows the actual capability registry" do
    for tools <- [[Alto.Contrib.Tools.RunShell], [RunCommand, Alto.Contrib.Tools.RunShell]] do
      prompt = Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: tools})
      assert prompt =~ "Use run_shell"
      assert prompt =~ "errexit has exceptions"
      refute prompt =~ "Command execution is disabled"
      refute prompt =~ "read-only"
    end

    refute Alto.Contrib.Prompts.Coding.build(%{cwd: "/workspace", tools: [RunCommand]}) =~
             "Use run_shell"
  end

  test "chat and coding builders share the same runtime prompt boundary" do
    assert %Alto.Runner.Result{status: :ok} =
             result =
             Alto.Contrib.run("say hello",
               loop: Alto.chat_loop(),
               prompt: &Alto.Contrib.Prompts.Chat.build(&1, identity: "Be pleasantly concise."),
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

    prompt =
      Alto.Prompt.build(&Alto.Contrib.Prompts.Coding.build/1, %{
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

    prompt =
      Alto.Prompt.build(&Alto.Contrib.Prompts.Coding.build/1, %{
        cwd: "/workspace",
        tools: [],
        project_instructions: instructions
      })

    assert prompt =~ "project instructions truncated"
  end

  test "uses literal text as the system message" do
    assert %Alto.Runner.Result{status: :ok} =
             Alto.Contrib.run("hello",
               provider: {AnswerProvider, test_pid: self()},
               prompt: "literal"
             )

    assert_receive {:request, %{messages: [%{"role" => "system", "content" => "literal"} | _]}}
  end
end
