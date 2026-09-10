defmodule Alto.Command.Executors.BubblewrapTest do
  use ExUnit.Case, async: true

  alias Alto.Command.Executors.Bubblewrap
  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @bwrap_path System.find_executable("bwrap")

  # Compile-time conditional skip. The tag records why Bubblewrap integration
  # tests are skipped when bwrap(1) is unavailable, and is nil (tests run)
  # when it is present.
  @bwrap_skip if @bwrap_path,
                do: nil,
                else: "bwrap(1) is not installed; Bubblewrap integration tests require it"

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    root = Path.join(System.tmp_dir!(), "alto-bwrap-workspace-#{suffix}")
    outside = Path.join(System.tmp_dir!(), "alto-bwrap-outside-#{suffix}")
    File.mkdir!(root)
    File.mkdir!(outside)
    File.write!(Path.join(outside, "secret"), "host-only")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    %{root: root, outside: outside, context: %Context{session_id: "test", cwd: root}}
  end

  @tag skip: @bwrap_skip
  test "mounts the workspace but hides unrelated host paths", context do
    secret = Path.join(context.outside, "secret")

    assert {:ok,
            %{
              exit_status: 0,
              output: "",
              sandbox: %{backend: :bubblewrap, network: :inherit, workspace: :read_write}
            }} =
             Alto.Command.run(
               %{
                 "program" => "sh",
                 "args" => [
                   "-c",
                   ~s(if [ -e "$1" ]; then exit 42; fi; printf isolated > sandbox.txt),
                   "alto",
                   secret
                 ]
               },
               context.context,
               executor: {Bubblewrap, network: :inherit}
             )

    assert File.read!(Path.join(context.root, "sandbox.txt")) == "isolated"
  end

  @tag skip: @bwrap_skip
  test "uses a clean, explicit target environment", %{context: context} do
    assert {:ok, %{exit_status: 0, output: "/tmp/alto-home|configured"}} =
             Alto.Command.run(
               %{
                 "program" => "sh",
                 "args" => ["-c", ~s(printf '%s|%s' "$HOME" "$ALTO_TEST_VALUE")]
               },
               context,
               executor:
                 {Bubblewrap, network: :inherit, env: %{"ALTO_TEST_VALUE" => "configured"}}
             )
  end

  @tag skip: @bwrap_skip
  test "prepares an inspectable sandbox profile before execution", %{context: context} do
    bubblewrap = @bwrap_path

    assert {:ok, prepared} =
             Alto.Command.prepare(%{"program" => "printf", "args" => ["hello"]}, context,
               executor:
                 {Bubblewrap,
                  bubblewrap: bubblewrap,
                  network: :inherit,
                  workspace: :read_only,
                  env: %{"ALTO_PROFILE" => "configured"}}
             )

    assert %{
             command: %{executable: executable, args: ["hello"], cwd: cwd},
             execution: %{
               backend: :bubblewrap,
               bubblewrap: ^bubblewrap,
               network: :inherit,
               workspace: :read_only,
               environment_variables: environment_variables
             }
           } = prepared.approval_details

    assert Path.type(executable) == :absolute
    assert cwd == context.cwd
    assert "ALTO_PROFILE" in environment_variables
    assert "HOME" in environment_variables
    assert "PATH" in environment_variables
  end

  @tag skip: @bwrap_skip
  test "reliably resumes the stopped process-group trampoline", %{context: context} do
    Enum.each(1..20, fn _attempt ->
      assert {:ok, %{exit_status: 0, termination: :exit}} =
               Alto.Command.run(
                 %{"program" => "printf", "args" => ["%s", ""], "timeout_ms" => 500},
                 context,
                 executor: {Bubblewrap, network: :inherit}
               )
    end)
  end

  @tag skip: @bwrap_skip
  test "can expose the workspace read-only", %{root: root, context: context} do
    assert {:ok,
            %{
              exit_status: status,
              sandbox: %{backend: :bubblewrap, workspace: :read_only}
            }} =
             Alto.Command.run(
               %{"program" => "sh", "args" => ["-c", "printf no > forbidden.txt"]},
               context,
               executor: {Bubblewrap, network: :inherit, workspace: :read_only}
             )

    assert status != 0
    refute File.exists?(Path.join(root, "forbidden.txt"))
  end

  test "fails closed when the configured bubblewrap executable is absent", %{context: context} do
    assert {:error, {:bubblewrap_not_executable, "/does/not/exist/bwrap"}} =
             Alto.Command.run(%{"program" => "printf"}, context,
               executor: {Bubblewrap, bubblewrap: "/does/not/exist/bwrap"}
             )
  end

  test "rejects invalid network modes before any execution", %{context: context} do
    for mode <- [:host, :bridge, "inherit", nil] do
      assert {:error, {:invalid_network_mode, ^mode}} =
               prepare_with_opts(context, network: mode)
    end
  end

  test "rejects invalid workspace modes before any execution", %{context: context} do
    for mode <- [:host, :readonly, "read_write"] do
      assert {:error, {:invalid_workspace_mode, ^mode}} =
               prepare_with_opts(context, workspace: mode)
    end
  end

  test "rejects invalid mount path option values", %{context: context} do
    cases = [
      {:read_only_paths, "not-a-list", {:invalid_mount_paths, :read_only_paths, "not-a-list"}},
      {:read_only_paths, [123], {:invalid_mount_paths, :read_only_paths, [123]}},
      {:writable_paths, ["relative/path"],
       {:invalid_mount_paths, :writable_paths, ["relative/path"]}},
      {:writable_paths, ["/alto/does/not/exist"],
       {:invalid_mount_paths, :writable_paths, ["/alto/does/not/exist"]}},
      {:read_only_paths, ["/alto/does/not/exist"],
       {:invalid_mount_paths, :read_only_paths, ["/alto/does/not/exist"]}}
    ]

    for {key, value, expected} <- cases do
      assert {:error, ^expected} = prepare_with_opts(context, [{key, value}])
    end
  end

  test "rejects invalid environment option values", %{context: context} do
    cases = [
      {:not_a_map, {:invalid_environment, :not_a_map}},
      {["not-a-pair"], {:invalid_environment_entry, "not-a-pair"}},
      {%{"NAME" => 42}, {:invalid_environment_entry, {"NAME", 42}}},
      {%{"A=B" => "x"}, {:invalid_environment_entry, "A=B"}},
      {%{"NUL\0NAME" => "x"}, {:invalid_environment_entry, "NUL\0NAME"}},
      {%{"NAME" => "value\0nul"}, {:invalid_environment_entry, "NAME"}},
      {%{"" => "x"}, {:invalid_environment_entry, {"", "x"}}}
    ]

    for {env, expected} <- cases do
      assert {:error, ^expected} = prepare_with_opts(context, env: env)
    end
  end

  test "rejects missing or non-executable configured bubblewrap binaries", %{
    context: context,
    root: root
  } do
    assert {:error, {:bubblewrap_not_executable, "/does/not/exist/bwrap"}} =
             prepare_with_opts(context, bubblewrap: "/does/not/exist/bwrap")

    assert {:error, {:bubblewrap_not_executable, ^root}} =
             prepare_with_opts(context, bubblewrap: root)

    nonexec = Path.join(root, "bwrap-nonexec")
    File.write!(nonexec, "#!/bin/sh\n")
    File.chmod!(nonexec, 0o644)

    assert {:error, {:bubblewrap_not_executable, ^nonexec}} =
             prepare_with_opts(context, bubblewrap: nonexec)

    assert {:error, {:invalid_bubblewrap, 123}} =
             prepare_with_opts(context, bubblewrap: 123)
  end

  test "approval details list environment names without their values", %{context: context} do
    secret = "super-secret-value-3f7a"

    assert {:ok, _prepared, details} =
             prepare_with_opts(context,
               env: %{"ALTO_TOKEN" => secret, "PATH" => "/custom/bin"}
             )

    assert details.environment_variables == ["ALTO_TOKEN", "HOME", "LANG", "PATH"]
    refute inspect(details) =~ secret
  end

  test "option-validation failures prevent the target command and never fall back to the host", %{
    context: context,
    root: root
  } do
    marker = Path.join(root, "host-ran")
    healthy = System.find_executable("true") || raise "true executable required"

    cases = [
      {[network: :host, bubblewrap: healthy], {:invalid_network_mode, :host}},
      {[workspace: :host, bubblewrap: healthy], {:invalid_workspace_mode, :host}},
      {[read_only_paths: ["/alto/does/not/exist"], bubblewrap: healthy],
       {:invalid_mount_paths, :read_only_paths, ["/alto/does/not/exist"]}},
      {[env: %{"NUL\0NAME" => "x"}, bubblewrap: healthy],
       {:invalid_environment_entry, "NUL\0NAME"}},
      {[bubblewrap: "/does/not/exist/bwrap"],
       {:bubblewrap_not_executable, "/does/not/exist/bwrap"}}
    ]

    for {opts, expected} <- cases do
      assert {:error, ^expected} =
               Alto.Command.run(
                 %{"program" => "sh", "args" => ["-c", "touch " <> marker], "timeout_ms" => 100},
                 context,
                 executor: {Bubblewrap, opts}
               )
    end

    refute File.exists?(marker)
  end

  defp prepare_with_opts(%Context{} = context, opts) do
    healthy = System.find_executable("true") || raise "true executable required"

    Bubblewrap.prepare(invocation(context.cwd), Keyword.put_new(opts, :bubblewrap, healthy))
  end

  defp invocation(cwd) do
    %Invocation{
      requested_program: "printf",
      executable: System.find_executable("printf") || "/usr/bin/printf",
      args: ["hello"],
      cwd: cwd,
      timeout_ms: 1_000,
      max_output_bytes: 1_000
    }
  end
end
