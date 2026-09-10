defmodule Alto.External.ProcessTest do
  use ExUnit.Case, async: false

  alias Alto.External.Process, as: ExternalProcess

  test "closing a process group stops its child and grandchild" do
    root = Path.join(System.tmp_dir!(), "alto-process-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    child = Path.join(root, "child")
    grandchild = Path.join(root, "grandchild")

    script =
      "(sleep 0.2; echo child > #{child}) & (sleep 0.4; echo grandchild > #{grandchild}) & wait"

    {:ok, process} =
      ExternalProcess.open(System.find_executable("sh"), ["-c", script],
        cwd: root,
        startup_timeout: 1_000
      )

    assert :ok = ExternalProcess.close(process)
    Process.sleep(600)
    refute File.exists?(child)
    refute File.exists?(grandchild)
  end

  test "an owner killed while a process is running still cleans the whole group" do
    root =
      Path.join(System.tmp_dir!(), "alto-process-owner-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    parent = self()
    child = Path.join(root, "child")
    grandchild = Path.join(root, "grandchild")

    script =
      "(sleep 0.2; echo child > #{child}) & (sleep 0.4; echo grandchild > #{grandchild}) & wait"

    owner =
      spawn(fn ->
        {:ok, _process} =
          ExternalProcess.open(System.find_executable("sh"), ["-c", script],
            cwd: root,
            startup_timeout: 1_000
          )

        send(parent, {:process_ready, self()})
        receive do: (:never -> :ok)
      end)

    assert_receive {:process_ready, ^owner}, 2_000
    Process.exit(owner, :kill)
    Process.sleep(600)
    refute File.exists?(child)
    refute File.exists?(grandchild)
  end

  test "stopping the MCP client cleans its child process group" do
    root = Path.join(System.tmp_dir!(), "alto-mcp-process-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    child = Path.join(root, "child")
    grandchild = Path.join(root, "grandchild")

    script =
      "printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{}}}\\n'; " <>
        "(sleep 0.2; echo child > " <>
        child <>
        ") & " <>
        "(sleep 0.4; echo grandchild > " <> grandchild <> ") & wait"

    {:ok, client} =
      Alto.External.MCP.Client.ensure_started(
        command: System.find_executable("sh"),
        args: ["-c", script],
        cwd: root,
        startup_timeout: 1_000
      )

    assert :ok = Alto.External.MCP.Client.stop(client)
    Process.sleep(600)
    refute File.exists?(child)
    refute File.exists?(grandchild)
  end
end
