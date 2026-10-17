defmodule Alto.Contrib.Socket.SSHTest do
  use ExUnit.Case, async: false

  test "validates forwarding inputs before launching ssh" do
    assert {:error, :invalid_host} =
             Alto.Contrib.Socket.SSH.open("-host", "/tmp/remote", ssh: "/missing")

    assert {:error, :invalid_host} =
             Alto.Contrib.Socket.SSH.open(" host", "/tmp/remote", ssh: "/missing")

    assert {:error, :invalid_host} =
             Alto.Contrib.Socket.SSH.open("user name", "/tmp/remote", ssh: "/missing")

    assert {:error, :invalid_remote_socket} =
             Alto.Contrib.Socket.SSH.open("host", "tmp/remote", ssh: "/missing")

    assert {:error, :invalid_remote_socket} =
             Alto.Contrib.Socket.SSH.open("host", "/tmp/a:b", ssh: "/missing")
  end

  test "startup timeout closes ssh and removes its socket directory" do
    fake = fake_ssh(false)
    on_exit(fn -> File.rm_rf!(Path.dirname(fake)) end)

    assert {:error, :timeout} =
             Alto.Contrib.Socket.SSH.open("host", "/run/alto.sock", ssh: fake, timeout: 100)

    refute Enum.any?(
             Path.wildcard(Path.join(System.tmp_dir!(), "alto_resident-ssh-*/forward.sock"))
           )

    eventually(fn ->
      assert File.exists?(pid_file(fake))
      refute os_process_alive?(fake_pid(fake))
    end)
  end

  test "owns a fake ssh process, forwards safely, and cleans up" do
    fake = fake_ssh()
    on_exit(fn -> File.rm_rf!(Path.dirname(fake)) end)

    assert {:ok, tunnel} =
             Alto.Contrib.Socket.SSH.open("user@host", "/run/alto.sock",
               ssh: fake,
               timeout: 1_000,
               port: 2222
             )

    local = Alto.Contrib.Socket.SSH.path(tunnel)
    child_pid = fake_pid(fake)
    assert File.exists?(local)
    assert {:ok, %{mode: mode}} = File.stat(Path.dirname(local))
    assert Bitwise.band(mode, 0o777) == 0o700
    args = File.read!(Path.join(Path.dirname(fake), "args"))
    assert args =~ "-L\n#{local}:/run/alto.sock"
    assert args =~ "-p\n2222"
    assert args =~ "ServerAliveInterval=15"
    assert args =~ "ServerAliveCountMax=3"
    assert :ok = Alto.Contrib.Socket.SSH.close(tunnel)
    refute File.exists?(Path.dirname(local))
    eventually(fn -> refute os_process_alive?(child_pid) end)
  end

  test "owner death closes the tunnel" do
    fake = fake_ssh()
    parent = self()

    owner =
      spawn(fn ->
        assert {:ok, tunnel} =
                 Alto.Contrib.Socket.SSH.open("host", "/run/alto.sock", ssh: fake, timeout: 1_000)

        send(parent, {:tunnel, Alto.Contrib.Socket.SSH.path(tunnel)})
      end)

    assert_receive {:tunnel, local}, 2_000
    refute Process.alive?(owner)
    eventually(fn -> refute File.exists?(Path.dirname(local)) end)
    File.rm_rf!(Path.dirname(fake))
  end

  defp fake_ssh(create_socket \\ true) do
    dir =
      Path.join(System.tmp_dir!(), "alto_resident-ssh-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "fake-ssh")

    listener =
      if create_socket,
        do: "\nserver = socket.socket(socket.AF_UNIX)\nserver.bind(sock)\nserver.listen(1)",
        else: ""

    File.write!(path, """
    #!/usr/bin/env python3
    import os
    import signal
    import socket
    import sys
    import time

    arguments = sys.argv[1:]
    with open(os.path.join(os.path.dirname(__file__), "args"), "w") as output:
        output.write("\\n".join(arguments) + "\\n")
    with open(os.path.join(os.path.dirname(__file__), "pid"), "w") as output:
        output.write(str(os.getpid()))
    sock = arguments[arguments.index("-L") + 1].split(":", 1)[0]
    #{listener}

    def stop(_signum, _frame):
        if "server" in globals():
            server.close()
        try:
            os.unlink(sock)
        except FileNotFoundError:
            pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        time.sleep(1)
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp pid_file(fake), do: fake |> Path.dirname() |> Path.join("pid")
  defp fake_pid(fake), do: fake |> pid_file() |> File.read!() |> String.to_integer()

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    try do
      fun.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
