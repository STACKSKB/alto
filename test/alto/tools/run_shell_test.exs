defmodule Alto.Tools.RunShellTest do
  use ExUnit.Case, async: true

  alias Alto.Tools.RunShell

  defmodule RecordingExecutor do
    @behaviour Alto.Command.Executor

    @impl true
    def prepare(invocation, opts) do
      send(Keyword.fetch!(opts, :owner), {:prepared, invocation})
      {:ok, invocation, %{backend: :recording}}
    end

    @impl true
    def execute(_invocation), do: {:ok, %{exit_status: 0}}
  end

  @context %{session_id: "run-shell-test", cwd: File.cwd!()}

  test "schema provides a single bounded command string and shared execution limits" do
    schema = RunShell.schema()
    properties = schema.parameters.properties

    assert schema.description =~ "Bash"
    assert properties.command.type == "string"
    assert properties.command.minLength == 1
    assert properties.command.maxLength == 60_000
    assert properties.timeout_ms.default == 30_000
    assert properties.timeout_ms.maximum == 120_000
    assert properties.max_output_bytes.default == 64_000
  end

  test "preparation uses Bash fail-fast pipeline flags and the configured executor" do
    assert RunShell.execution_mode([]) == :exclusive
    assert RunShell.approval([]) == :required

    assert {:ok, prepared, details} =
             Alto.Tool.prepare(
               RunShell,
               %{"command" => "make test | tail -20", "timeout_ms" => 5_000},
               @context,
               executor: {RecordingExecutor, owner: self()}
             )

    assert_received {:prepared,
                     %{
                       requested_program: "bash",
                       args: ["-e", "-o", "pipefail", "-c", "make test | tail -20"],
                       cwd: cwd,
                       timeout_ms: 5_000,
                       max_output_bytes: 64_000
                     }}

    assert cwd == @context.cwd
    assert details.execution == %{backend: :recording}
    assert {:ok, %{exit_status: 0}} = RunShell.run(prepared, %{})

    command = "printf '%s\\n' 'hello world'\nprintf '%s' second"

    assert {:ok, _prepared, _details} =
             Alto.Tool.prepare(
               RunShell,
               %{"command" => command},
               @context,
               %{executor: {RecordingExecutor, owner: self()}}
             )

    assert_received {:prepared, %{args: ["-e", "-o", "pipefail", "-c", ^command]}}
  end

  test "pipefail and errexit stop after a failed pipeline stage" do
    assert {:ok, %{exit_status: status, timed_out: false} = result} =
             Alto.Tool.run(
               RunShell,
               %{"command" => "false | true; printf UNEXPECTED"},
               @context,
               executor: {Alto.Command.Executors.Unsandboxed, []}
             )

    assert status != 0
    refute result.output =~ "UNEXPECTED"
  end

  test "a script can explicitly disable fail-fast defaults for intentional failures" do
    assert {:ok, %{exit_status: 0, output: output}} =
             Alto.Tool.run(
               RunShell,
               %{"command" => "set +e; set +o pipefail; false | true; printf intentional"},
               @context,
               executor: {Alto.Command.Executors.Unsandboxed, []}
             )

    assert output == "intentional"
  end

  test "NUL bytes in a shell command are rejected before execution" do
    assert {:error, :argument_contains_nul} =
             Alto.Tool.prepare(
               RunShell,
               %{"command" => "printf before" <> <<0>> <> "printf after"},
               @context,
               executor: {Alto.Command.Executors.Unsandboxed, []}
             )
  end

  test "command limit is enforced before execution" do
    assert {:error, %NimbleOptions.ValidationError{key: :command}} =
             Alto.Tool.prepare(
               RunShell,
               %{"command" => String.duplicate("x", 60_001)},
               @context,
               executor: {Alto.Command.Executors.Unsandboxed, []}
             )
  end
end
