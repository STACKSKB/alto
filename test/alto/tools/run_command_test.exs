defmodule Alto.Tools.RunCommandTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Context
  alias Alto.Tools.RunCommand

  @stop_observer File.regular?("/proc/self/status") || System.find_executable("ps")

  @trampoline_binaries System.find_executable("kill") && System.find_executable("sh") &&
                         @stop_observer
  @fallback_binaries System.find_executable("elixir") && System.find_executable("erl")

  # Compile-time conditional skips. Each tag records why the platform
  # integration test is skipped, and is nil when the test can run.
  @trampoline_skip if @trampoline_binaries,
                     do: nil,
                     else:
                       "kill(1), sh(1), and procfs or ps(1) are required to test the process-group trampoline"

  @fallback_skip if @fallback_binaries,
                   do: nil,
                   else: "elixir(1) and erl(1) are required to probe degraded cleanup"

  setup do
    root = Path.join(System.tmp_dir!(), "alto-command-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: %Context{session_id: "test", cwd: root}}
  end

  test "runs one executable directly and captures its exit", %{context: context} do
    assert {:ok,
            %{
              output: "hello",
              exit_status: 0,
              termination: :exit,
              truncated: false,
              timed_out: false
            }} =
             RunCommand.run(%{"program" => "printf", "args" => ["%s", "hello"]}, context)
  end

  test "stops reading and closes the port at the output limit", %{context: context} do
    assert {:ok,
            %{
              output: "abc",
              exit_status: nil,
              termination: :output_limit,
              truncated: true
            }} =
             RunCommand.run(
               %{"program" => "printf", "args" => ["abcdef"], "max_output_bytes" => 3},
               context
             )
  end

  # The deadline covers process spawn and trampoline setup as well as
  # execution, so the budget must fit scheduling delays under parallel load.
  test "closes a command that passes its deadline", %{context: context} do
    assert {:ok,
            %{
              exit_status: nil,
              termination: :timeout,
              timed_out: true
            }} =
             RunCommand.run(
               %{"program" => "sleep", "args" => ["5"], "timeout_ms" => 100},
               context
             )
  end

  test "does not invoke a shell to resolve command syntax", %{context: context} do
    assert {:error, {:executable_not_found, "printf hello"}} =
             RunCommand.run(%{"program" => "printf hello"}, context)
  end

  @tag skip: @trampoline_skip
  test "cleans up descendants after the top-level program exits", %{root: root, context: context} do
    marker = Path.join(root, "orphaned")

    assert {:ok, %{exit_status: 0}} =
             RunCommand.run(
               %{
                 "program" => "sh",
                 "args" => ["-c", "(sleep 0.2; touch orphaned) >/dev/null 2>&1 &"]
               },
               context
             )

    Process.sleep(350)
    refute File.exists?(marker)
  end

  @tag skip: @trampoline_skip
  test "kills the process group when the calling task is killed", %{
    root: root,
    context: context
  } do
    pidfile = Path.join(root, "cmd.pid")
    parent = self()

    caller =
      spawn(fn ->
        result =
          RunCommand.run(
            %{"program" => "sh", "args" => ["-c", "echo $$ > #{pidfile}; exec sleep 300"]},
            context
          )

        send(parent, {:caller_done, result})
      end)

    wait_until(fn -> File.exists?(pidfile) end)
    child_pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()

    # Mirrors how Alto.Runner.Serial tears down an in-flight tool task with
    # Task.shutdown(task, :brutal_kill) on cancellation or tool timeout.
    Process.exit(caller, :kill)

    wait_until(fn -> not os_process_alive?(child_pid) end)
    refute os_process_alive?(child_pid)
  end

  @tag skip: @fallback_skip
  test "logs a degradation warning and still bounds execution without trampoline binaries", %{
    root: root
  } do
    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    File.ln_s!(System.find_executable("erl"), Path.join(bin, "erl"))
    File.ln_s!("/bin/sleep", Path.join(bin, "sleep"))
    File.ln_s!("/usr/bin/dirname", Path.join(bin, "dirname"))
    File.ln_s!("/usr/bin/basename", Path.join(bin, "basename"))
    File.ln_s!("/usr/bin/readlink", Path.join(bin, "readlink"))
    File.ln_s!("/usr/bin/cut", Path.join(bin, "cut"))
    File.ln_s!("/usr/bin/sed", Path.join(bin, "sed"))
    File.ln_s!("/usr/bin/mkdir", Path.join(bin, "mkdir"))

    script = """
    {:ok, _} = Application.ensure_all_started(:logger)

    result =
      Alto.Tools.RunCommand.run(
        %{"program" => "sleep", "args" => ["1"], "timeout_ms" => 10},
        %Alto.Tool.Context{session_id: "probe", cwd: #{inspect(root)}}
      )

    IO.inspect(result, limit: :infinity)
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", ebin_path(), "-e", script],
        env: [{"PATH", bin}],
        stderr_to_stdout: true
      )

    assert status == 0, "fallback probe failed: #{output}"
    assert output =~ "termination: :timeout"
    assert output =~ "process-group cleanup"
  end

  # The os_pid of a port is assigned asynchronously after Port.open, so a child
  # that is slow to appear must not be misreported as exited-before-start nor
  # leak as a stopped process. The window itself is internal to ERTS and cannot
  # be widened from outside; this probe exercises delayed child startup through
  # a PATH-shimmed shell to guard the wait-and-resume machinery around it.
  @tag skip: @trampoline_skip
  test "runs a command whose child starts slowly under the trampoline", %{root: root} do
    bin = Path.join(root, "bin")
    File.mkdir!(bin)

    real_sh = System.find_executable("sh")

    File.write!(Path.join(bin, "sh"), """
    #!/bin/sh
    sleep 0.2
    exec #{real_sh} "$@"
    """)

    File.chmod!(Path.join(bin, "sh"), 0o755)

    trampoline_names = [
      "kill",
      "sleep",
      "printf",
      "erl",
      "dirname",
      "basename",
      "readlink",
      "cut",
      "sed",
      "mkdir"
    ]

    for name <- trampoline_names do
      File.ln_s!(System.find_executable(name), Path.join(bin, name))
    end

    script = """
    {:ok, _} = Application.ensure_all_started(:logger)

    result =
      Alto.Tools.RunCommand.run(
        %{"program" => "printf", "args" => ["%s", "slow"], "timeout_ms" => 10_000},
        %Alto.Tool.Context{session_id: "probe", cwd: #{inspect(root)}}
      )

    IO.inspect(result, limit: :infinity)
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", ebin_path(), "-e", script],
        env: [{"PATH", bin}],
        stderr_to_stdout: true
      )

    assert status == 0, "slow-start probe failed: #{output}"
    assert output =~ "output: \"slow\""
    assert output =~ "termination: :exit"
    refute output =~ "process-group cleanup"
  end

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp ebin_path do
    Application.app_dir(:alto, "ebin")
  end
end
