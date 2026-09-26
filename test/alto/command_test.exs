defmodule Alto.CommandTest do
  use ExUnit.Case, async: false

  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  defmodule RecordingExecutor do
    @behaviour Alto.Command.Executor

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
    context = %Context{session_id: "test", cwd: File.cwd!()}
    %{context: context}
  end

  test "a policy prepares a resolved invocation for a replaceable executor", %{context: context} do
    assert {:ok, %{backend: :recording}} =
             Alto.Command.run(%{"program" => "printf", "args" => ["hello"]}, context,
               executor: {RecordingExecutor, test_pid: self()}
             )

    assert_receive {:execute,
                    %Invocation{
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
             Alto.Command.prepare(%{"program" => "printf", "args" => ["hello"]}, context,
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

    assert {:ok, %{backend: :recording}} = Alto.Command.execute(prepared)
    assert_receive {:execute, %Invocation{executable: ^executable}}
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

    assert {:ok, prepared} = Alto.Command.prepare(%{"program" => "alto-path-probe"}, context)
    assert prepared.approval_details.command.executable == Path.join(first, "alto-path-probe")

    System.put_env("PATH", second <> ":" <> inherited_path)

    assert {:ok, %{output: "first", exit_status: 0}} = Alto.Command.execute(prepared)
  end

  test "command policy can reject before an executor is called", %{context: context} do
    assert {:error, :locked_down} =
             Alto.Command.run(%{"program" => "printf"}, context,
               policy: {Alto.Command.Policies.DenyAll, reason: :locked_down},
               executor: {RecordingExecutor, test_pid: self()}
             )

    refute_receive {:prepare_execution, _invocation}
    refute_receive {:execute, _invocation}
  end

  test "rejects a non-list args value before reaching the executor", %{context: context} do
    assert {:error, :arguments_must_be_list} =
             Alto.Command.run(%{"program" => "printf", "args" => "not-a-list"}, context,
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
