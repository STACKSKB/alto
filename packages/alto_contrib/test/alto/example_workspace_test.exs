defmodule Alto.ExampleWorkspaceTest do
  use ExUnit.Case, async: false

  @config Path.expand("../../../../alto.example.workspace.exs", __DIR__)
  @bwrap_skip if System.find_executable("bwrap"),
                do: nil,
                else: "bwrap(1) is required for the workspace example integration test"

  setup do
    model = System.get_env("ALTO_MODEL")
    System.put_env("ALTO_MODEL", "test-model")

    on_exit(fn ->
      if model, do: System.put_env("ALTO_MODEL", model), else: System.delete_env("ALTO_MODEL")
    end)

    root =
      Path.join(System.tmp_dir!(), "alto-example-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "original")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, options} = Alto.Contrib.Config.load(@config)

    options =
      Keyword.merge(options,
        cwd: root,
        session_dir: Path.join(root, "sessions"),
        loop: Alto.rule_loop(steps: ["run_shell"])
      )

    %{root: root, options: options}
  end

  @tag skip: @bwrap_skip
  test "workspace commands preserve Git, isolate networking and retain oversized output", ctx do
    {host_network, 0} = System.cmd("readlink", ["/proc/self/ns/net"])
    owner = self()

    options =
      Keyword.put(ctx.options, :approval, fn request, _context ->
        send(owner, {:approval, request.tool})
        :approve
      end)

    result =
      Alto.Contrib.run(
        %{
          "command" =>
            "if printf changed > .git/config 2>/dev/null; then exit 41; fi; " <>
              "printf writable > result.txt; " <>
              "readlink /proc/self/ns/net > network.txt; " <>
              "printf '%070000d' 0"
        },
        options
      )

    assert result.status == :ok
    assert_received {:approval, "run_shell"}
    assert [output] = result.output
    assert output.exit_status == 0
    assert output.truncated
    assert %{path: retained, bytes: bytes, truncated: false} = output.output_retention
    assert bytes >= 70_000
    assert File.read!(Path.join(ctx.root, ".git/config")) == "original"
    assert File.read!(Path.join(ctx.root, "result.txt")) == "writable"
    refute File.read!(Path.join(ctx.root, "network.txt")) == host_network
    assert File.stat!(Path.join(ctx.root, retained)).size == bytes

    assert {:ok, %{content: content}} =
             Alto.Tool.run(
               Alto.Contrib.Tools.ReadFile,
               %{"path" => retained, "offset" => bytes - 8, "limit" => 8},
               %{cwd: ctx.root}
             )

    assert content == "00000000"
  end

  @tag skip: @bwrap_skip
  test "denied commands create neither command output nor retention slots", ctx do
    result =
      Alto.Contrib.run(
        %{"command" => "printf denied > should-not-exist.txt"},
        Keyword.put(ctx.options, :approval, {:deny, :test_denied})
      )

    assert result.status == :error
    assert result.reason == {:rule_step_failed, 1, "run_shell", {:approval_denied, :test_denied}}
    refute File.exists?(Path.join(ctx.root, "should-not-exist.txt"))
    refute File.exists?(Path.join(ctx.root, ".alto/command-output"))
  end
end
