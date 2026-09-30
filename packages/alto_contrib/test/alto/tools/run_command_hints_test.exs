defmodule Alto.Contrib.Tools.RunCommandHintsTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Tools.RunCommand

  defmodule RecordingExecutor do
    def execute({pid, command, result}) do
      send(pid, {:executed, command})
      result
    end
  end

  defp run(program, args, result, metadata \\ :command) do
    command = %{requested_program: program, args: args, cwd: "/workspace"}

    prepared = %{
      executor: RecordingExecutor,
      execution: {self(), command, result},
      approval_details: if(metadata == :command, do: %{command: command}, else: %{})
    }

    actual = RunCommand.run(prepared, %{})
    assert_received {:executed, ^command}
    refute_received {:executed, _}
    actual
  end

  test "failed repeated executable adds actionable feedback after exactly one execution" do
    original = %{exit_status: 2, termination: :exit, output: "ls: cannot access ls"}
    assert {:ok, result} = run("ls", ["ls"], {:ok, original})
    assert Map.delete(result, :hint) == original
    assert result.hint.code == :repeated_program_argument
    assert result.hint.message =~ "omit that first args item"
    assert result.hint.message =~ "No retry was performed"
    assert result.hint.retry_performed == false
  end

  test "successful repeated argument is untouched" do
    result = {:ok, %{exit_status: 0, termination: :exit, output: "ls"}}
    assert run("printf", ["printf"], result) == result
  end

  test "ordinary failure is untouched" do
    result = {:ok, %{exit_status: 2, termination: :exit, output: "bad option"}}
    assert run("ls", ["--bad-option"], result) == result
  end

  test "explicit relative paths normalize without equating executable basenames" do
    result = {:ok, %{exit_status: 1, output: "failed"}}

    assert {:ok, %{hint: %{code: :repeated_program_argument}}} =
             run("./bin/probe", ["bin/../bin/probe"], result)

    assert run("./bin/probe", ["probe"], result) == result
    assert run("probe", ["./probe"], result) == result
    assert run("./bin/probe", ["./other/probe"], result) == result
  end

  test "timeouts, executor errors, and missing command metadata are untouched" do
    timeout = {:ok, %{exit_status: 1, termination: :timeout, output: ""}}
    assert run("ls", ["ls"], timeout) == timeout
    assert run("ls", ["ls"], {:error, :unavailable}) == {:error, :unavailable}
    result = {:ok, %{exit_status: 1, output: "failed"}}
    assert run("ls", ["ls"], result, :missing) == result
  end
end
