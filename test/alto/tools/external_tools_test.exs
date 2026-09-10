defmodule Alto.Tools.ExternalToolsTest do
  use ExUnit.Case, async: true

  alias Alto.Command.Prepared
  alias Alto.Tool.Context
  alias Alto.Tools.GitInspect
  alias Alto.Tools.GitMutate
  alias Alto.Tools.Ripwire

  defmodule ResultExecutor do
    @behaviour Alto.Command.Executor

    @impl true
    def prepare(invocation, opts),
      do: {:ok, {invocation, Keyword.fetch!(opts, :result)}, %{backend: :test}}

    @impl true
    def execute({_invocation, result}), do: result
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-external-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "--quiet"], cd: root)
    File.write!(Path.join(root, "sample.txt"), "hello\n")
    context = %Context{session_id: "test", cwd: root}
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: context}
  end

  test "Git inspection delegates to the installed CLI with bounded output", %{context: context} do
    assert {:ok, %{output: output, exit_status: 0}} =
             GitInspect.run(%{"action" => "status"}, context)

    assert output =~ "sample.txt"
  end

  test "Git inspection disables configured helper and conversion paths", %{
    root: root,
    context: context
  } do
    executable = Path.join(root, "fake-git")
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(executable, 0o755)

    assert {:ok, %{output: output}} =
             GitInspect.run(%{"action" => "diff"}, context, executable: executable)

    assert output =~ "--no-optional-locks\n"
    assert output =~ "core.fsmonitor=false\n"
    assert output =~ "core.untrackedCache=false\n"
    assert output =~ "diff.external=\n"
    assert output =~ "interactive.diffFilter=\n"
    assert output =~ "--no-ext-diff\n"
    assert output =~ "--no-textconv\n"
  end

  test "Git inspection never invokes a configured external diff helper", %{
    root: root,
    context: context
  } do
    helper = Path.join(root, "external-diff")
    marker = Path.join(root, "helper-ran")

    File.write!(helper, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(helper, 0o755)
    System.cmd("git", ["add", "sample.txt"], cd: root)
    File.write!(Path.join(root, "sample.txt"), "changed\n")
    System.cmd("git", ["config", "diff.external", helper], cd: root)

    assert {:ok, %{output: output}} = GitInspect.run(%{"action" => "diff"}, context)
    refute File.exists?(marker)
    assert output =~ "sample.txt"
  end

  test "Git mutation freezes a narrow command before approval", %{context: context} do
    assert {:ok, %Prepared{} = prepared, details} =
             GitMutate.prepare(%{"action" => "stage", "paths" => ["sample.txt"]}, context)

    assert details.command.args |> List.last() == ":(top,literal)sample.txt"
    assert prepared.invocation.executable =~ "git"
  end

  test "Git rejects option-shaped refs and absolute or parent pathspecs", %{context: context} do
    assert {:error, {:invalid_git_ref, "--all"}} =
             GitInspect.run(%{"action" => "show", "ref" => "--all"}, context)

    assert {:error, {:invalid_git_path, "/tmp/x"}} =
             GitMutate.prepare(%{"action" => "stage", "paths" => ["/tmp/x"]}, context)

    assert {:error, {:invalid_git_path, "../x"}} =
             GitMutate.prepare(%{"action" => "stage", "paths" => ["../x"]}, context)
  end

  test "Git mutation reports known command failures and uncertain dispatches", %{context: context} do
    known_failure = {:ok, %{exit_status: 2, termination: :exit, output: "bad branch\n"}}

    assert {:ok, prepared, _details} =
             GitMutate.prepare(
               %{"action" => "commit", "message" => "message"},
               context,
               executor: {ResultExecutor, result: known_failure}
             )

    assert {:error, {:git_failed, 2, "bad branch\n"}} =
             GitMutate.run_prepared(prepared, context)

    timeout = {:ok, %{exit_status: nil, termination: :timeout, output: ""}}

    assert {:ok, prepared, _details} =
             GitMutate.prepare(
               %{"action" => "commit", "message" => "message"},
               context,
               executor: {ResultExecutor, result: timeout}
             )

    assert {:unknown, :git_timeout} = GitMutate.run_prepared(prepared, context)
  end

  test "Ripwire adapter invokes the configured external binary, not an internal implementation",
       %{
         root: root,
         context: context
       } do
    executable = Path.join(root, "fake-ripwire")
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(executable, 0o755)

    assert {:ok, %{output: output}} =
             Ripwire.run(
               %{"action" => "pack_task", "query" => "add mcp", "top_k" => 12},
               context,
               executable: executable
             )

    assert output == ".\n--pack-task=add mcp\n--top-k=12\n"
  end

  test "Ripwire gate statuses are successful domain verdicts", %{
    root: root,
    context: context
  } do
    executable = Path.join(root, "fake-ripwire-gates")

    File.write!(
      executable,
      "#!/bin/sh\n" <>
        "case \"$2\" in\n" <>
        "  --test-gate) printf 'tests required\\n'; exit 4 ;;\n" <>
        "  --quality-delta) printf 'regressions found\\n'; exit 2 ;;\n" <>
        "esac\n"
    )

    File.chmod!(executable, 0o755)

    assert {:ok, %{gate: :obligations, exit_status: 4, output: "tests required\n"}} =
             Ripwire.run(%{"action" => "test_gate"}, context, executable: executable)

    assert {:ok, %{gate: :regressions, exit_status: 2, output: "regressions found\n"}} =
             Ripwire.run(%{"action" => "quality_delta"}, context, executable: executable)
  end
end
