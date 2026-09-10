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

  # Callback-incomplete modules deliberately omit the @behaviour declaration so
  # the compiler does not reject them at compile time; the runtime contract
  # check in Alto.Command is what these tests exercise.
  defmodule NoPolicyCallbacks do
  end

  defmodule MalformedPolicyReturn do
    @behaviour Alto.Command.Policy

    @impl true
    def prepare(_arguments, _context, _opts), do: {:ok, :not_an_invocation}
  end

  defmodule RawPolicyReturn do
    @behaviour Alto.Command.Policy

    @impl true
    def prepare(_arguments, _context, _opts), do: :plain_return
  end

  defmodule NoExecutorCallbacks do
  end

  defmodule NoExecutorExecute do
    def prepare(_invocation, _opts), do: {:ok, :execution, %{}}
  end

  defmodule RawExecutorReturn do
    @behaviour Alto.Command.Executor

    @impl true
    def prepare(_invocation, _opts), do: :raw_return

    @impl true
    def execute(_execution), do: {:ok, %{}}
  end

  defmodule TwoTupleExecutorReturn do
    @behaviour Alto.Command.Executor

    @impl true
    def prepare(_invocation, _opts), do: {:ok, :execution}

    @impl true
    def execute(_execution), do: {:ok, %{}}
  end

  defmodule NonMapExecutorDetails do
    @behaviour Alto.Command.Executor

    @impl true
    def prepare(_invocation, _opts), do: {:ok, :execution, "not-a-map"}

    @impl true
    def execute(_execution), do: {:ok, %{}}
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
    assert prepared.invocation.executable == Path.join(first, "alto-path-probe")

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

  test "rejects nonexistent or callback-incomplete policy modules", %{context: context} do
    for {spec, module} <- [
          {Alto.Command.Policies.NotFound, Alto.Command.Policies.NotFound},
          {NoPolicyCallbacks, NoPolicyCallbacks},
          {{NoPolicyCallbacks, []}, NoPolicyCallbacks}
        ] do
      assert {:error, {:invalid_command_component, :policy, ^module}} =
               Alto.Command.prepare(%{"program" => "printf"}, context, policy: spec)
    end
  end

  test "rejects nonexistent or callback-incomplete executor modules", %{context: context} do
    for {spec, module} <- [
          {Alto.Command.Executors.NotFound, Alto.Command.Executors.NotFound},
          {NoExecutorCallbacks, NoExecutorCallbacks},
          {NoExecutorExecute, NoExecutorExecute},
          {{NoExecutorCallbacks, []}, NoExecutorCallbacks}
        ] do
      assert {:error, {:invalid_command_component, :executor, ^module}} =
               Alto.Command.prepare(%{"program" => "printf"}, context, executor: spec)
    end
  end

  test "rejects policies that return malformed success values", %{context: context} do
    assert {:error, {:invalid_command_invocation, :not_an_invocation}} =
             Alto.Command.prepare(%{"program" => "printf"}, context,
               policy: MalformedPolicyReturn
             )

    assert {:error, {:invalid_command_policy_return, :plain_return}} =
             Alto.Command.prepare(%{"program" => "printf"}, context, policy: RawPolicyReturn)
  end

  test "rejects executors that return malformed preparation values", %{context: context} do
    assert {:error, {:invalid_command_executor_return, :raw_return}} =
             Alto.Command.prepare(%{"program" => "printf"}, context, executor: RawExecutorReturn)

    assert {:error, {:invalid_command_executor_return, {:ok, :execution}}} =
             Alto.Command.prepare(%{"program" => "printf"}, context,
               executor: TwoTupleExecutorReturn
             )
  end

  test "rejects executor preparation details that are not a map", %{context: context} do
    assert {:error, {:invalid_executor_approval_details, "not-a-map"}} =
             Alto.Command.prepare(%{"program" => "printf"}, context,
               executor: NonMapExecutorDetails
             )
  end

  defp write_executable(path, output) do
    File.write!(path, "#!/bin/sh\nprintf #{output}")
    File.chmod!(path, 0o755)
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
