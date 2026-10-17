defmodule Alto.Contrib.External.ProcessTest do
  use ExUnit.Case, async: false

  alias Alto.Contrib.External.Process, as: ExternalProcess

  @moduletag :tmp_dir

  test "closing a process group stops its child and grandchild", %{tmp_dir: root} do
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

  for reason <- [:normal, :killed] do
    @tag exit_reason: reason
    test "owner #{reason} exit cleans the whole process group", %{
      tmp_dir: root,
      exit_reason: reason
    } do
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
          receive do: (:stop -> :ok)
        end)

      assert_receive {:process_ready, ^owner}, 2_000
      if reason == :normal, do: send(owner, :stop), else: Process.exit(owner, :kill)
      Process.sleep(600)
      refute File.exists?(child)
      refute File.exists?(grandchild)
    end
  end

  test "stopping the MCP client cleans its child process group", %{tmp_dir: root} do
    child = Path.join(root, "child")
    grandchild = Path.join(root, "grandchild")

    script =
      "printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{}}}\\n'; " <>
        "(sleep 0.2; echo child > " <>
        child <>
        ") & " <>
        "(sleep 0.4; echo grandchild > " <> grandchild <> ") & wait"

    {:ok, client} =
      Alto.Contrib.External.MCP.Client.ensure_started(
        command: System.find_executable("sh"),
        args: ["-c", script],
        cwd: root,
        startup_timeout: 1_000
      )

    assert :ok = Alto.Contrib.External.MCP.Client.stop(client)
    Process.sleep(600)
    refute File.exists?(child)
    refute File.exists?(grandchild)
  end

  test "malformed JSON-RPC startup line reports a bounded error instead of crashing", %{
    tmp_dir: root
  } do
    server = Path.join(root, "bad-server")
    File.write!(server, "#!/bin/sh\nprintf '%s\\n' '{\"jsonrpc\":'\n")
    File.chmod!(server, 0o755)

    assert {:error, reason} =
             Alto.Contrib.External.MCP.Client.ensure_started(
               command: server,
               cwd: root,
               startup_timeout: 1_000
             )

    assert inspect(reason) =~ "json_rpc_invalid_json"
    refute inspect(reason) =~ "FunctionClauseError"
    refute inspect(reason) =~ ~s({"jsonrpc":)
  end

  test "missing and non-executable paths return startup errors", %{tmp_dir: root} do
    path = Path.join(root, "missing-executable")

    assert {:error, {:process_open_failed, :enoent}} = ExternalProcess.open(path, [])
    File.write!(path, "not executable")
    File.chmod!(path, 0o600)
    assert {:error, {:process_open_failed, :eacces}} = ExternalProcess.open(path, [])
  end

  test "readiness handshake does not consume the command's standard input" do
    {:ok, process} =
      ExternalProcess.open(System.find_executable("cat"), [], startup_timeout: 1_000)

    port = ExternalProcess.port(process)
    assert Port.command(port, "client payload\n")
    assert_receive {^port, {:data, "client payload\n"}}, 1_000
    assert :ok = ExternalProcess.close(process)
  end
end
