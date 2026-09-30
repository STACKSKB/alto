defmodule Alto.CommandTest do
  use ExUnit.Case, async: false

  defmodule RecordingExecutor do
    @behaviour Alto.Contrib.Command.Executor

    @impl true
    def prepare(invocation, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:prepare_execution, invocation})
      {:ok, {invocation, opts}, %{backend: :recording}}
    end

    @impl true
    def execute({invocation, opts}) do
      send(Keyword.fetch!(opts, :test_pid), {:execute, invocation})
      {:ok, %{backend: :recording}}
    end
  end

  setup do
    context = %{session_id: "test", cwd: File.cwd!()}
    %{context: context}
  end

  test "a captured policy prepares a resolved invocation for a replaceable executor", %{
    context: context
  } do
    allowed_programs = ["printf"]

    policy = fn arguments, context ->
      if arguments["program"] in allowed_programs,
        do: Alto.Contrib.Command.resolve(arguments, context),
        else: {:error, :program_not_allowed}
    end

    assert {:ok, %{backend: :recording}} =
             Alto.Contrib.Command.run(%{"program" => "printf", "args" => ["hello"]}, context,
               policy: policy,
               executor: {RecordingExecutor, test_pid: self()}
             )

    assert_receive {:execute,
                    %{
                      requested_program: "printf",
                      executable: executable,
                      args: ["hello"],
                      cwd: cwd
                    }}

    assert Path.type(executable) == :absolute
    assert cwd == context.cwd
  end

  test "preparation exposes the canonical command and executor profile", %{context: context} do
    assert {:ok, prepared} =
             Alto.Contrib.Command.prepare(%{"program" => "printf", "args" => ["hello"]}, context,
               executor: {RecordingExecutor, test_pid: self()}
             )

    assert %{
             command: %{
               requested_program: "printf",
               executable: executable,
               args: ["hello"],
               cwd: cwd
             },
             execution: %{backend: :recording}
           } = prepared.approval_details

    assert Path.type(executable) == :absolute
    assert cwd == context.cwd
    refute_receive {:execute, _invocation}

    assert {:ok, %{backend: :recording}} = Alto.Contrib.Command.execute(prepared)
    assert_receive {:execute, %{executable: ^executable}}
  end

  test "execution does not resolve PATH again after approval", %{context: context} do
    original_path = System.get_env("PATH")
    inherited_path = original_path || ""
    root = Path.join(System.tmp_dir!(), "alto-path-freeze-#{System.unique_integer([:positive])}")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)
    write_executable(Path.join(first, "alto-path-probe"), "first")
    write_executable(Path.join(second, "alto-path-probe"), "second")

    on_exit(fn ->
      restore_path(original_path)
      File.rm_rf!(root)
    end)

    System.put_env("PATH", first <> ":" <> inherited_path)

    assert {:ok, prepared} =
             Alto.Contrib.Command.prepare(%{"program" => "alto-path-probe"}, context)

    assert prepared.approval_details.command.executable == Path.join(first, "alto-path-probe")

    System.put_env("PATH", second <> ":" <> inherited_path)

    assert {:ok, %{output: "first", exit_status: 0}} = Alto.Contrib.Command.execute(prepared)
  end

  test "relative executable paths resolve against the task workspace before approval" do
    root = Path.join(System.tmp_dir!(), "alto-relative-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "build"))
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.join(root, "build/probe")
    write_executable(executable, "workspace")
    context = %{session_id: "test", cwd: root}

    for program <- ["./build/probe", "build/probe"] do
      assert {:ok, prepared} = Alto.Contrib.Command.prepare(%{"program" => program}, context)
      assert prepared.approval_details.command.executable == executable
      assert prepared.approval_details.command.requested_program == program

      assert {:ok, %{output: "workspace", exit_status: 0}} =
               Alto.Contrib.Command.execute(prepared)
    end

    assert {:error, {:executable_not_found, "./build/missing"}} =
             Alto.Contrib.Command.prepare(%{"program" => "./build/missing"}, context)
  end

  test "command policy can reject before an executor is called", %{context: context} do
    assert {:error, :locked_down} =
             Alto.Contrib.Command.run(%{"program" => "printf"}, context,
               policy: {:error, :locked_down},
               executor: {RecordingExecutor, test_pid: self()}
             )

    refute_receive {:prepare_execution, _invocation}
    refute_receive {:execute, _invocation}
  end

  test "rejects a non-list args value before reaching the executor", %{context: context} do
    assert {:error, %NimbleOptions.ValidationError{key: :args}} =
             Alto.Contrib.Command.run(%{"program" => "printf", "args" => "not-a-list"}, context,
               executor: {RecordingExecutor, test_pid: self()}
             )

    refute_receive {:execute, _invocation}
  end

  defp write_executable(path, output) do
    File.write!(path, "#!/bin/sh\nprintf #{output}")
    File.chmod!(path, 0o755)
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
