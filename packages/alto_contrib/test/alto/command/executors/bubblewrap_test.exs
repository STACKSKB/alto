defmodule Alto.Contrib.Command.Executors.BubblewrapTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Command.Executors.Bubblewrap

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

    %{root: root, outside: outside, context: %{session_id: "test", cwd: root}}
  end

  @tag skip: @bwrap_skip
  test "sandboxed finite commands also receive stdin EOF", %{context: context} do
    assert {:ok, %{exit_status: 1, timed_out: false}} =
             Alto.Contrib.Command.run(
               %{"program" => "grep", "args" => ["main"], "timeout_ms" => 5_000},
               context,
               executor: {Bubblewrap, network: :disabled}
             )
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
             Alto.Contrib.Command.run(
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
             Alto.Contrib.Command.run(
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
             Alto.Contrib.Command.prepare(%{"program" => "printf", "args" => ["hello"]}, context,
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
               Alto.Contrib.Command.run(
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
             Alto.Contrib.Command.run(
               %{"program" => "sh", "args" => ["-c", "printf no > forbidden.txt"]},
               context,
               executor: {Bubblewrap, network: :inherit, workspace: :read_only}
             )

    assert status != 0
    refute File.exists?(Path.join(root, "forbidden.txt"))
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

  test "does not create directories below the read-only system bind for existing mounts", %{
    context: context
  } do
    if File.dir?("/usr/local/share") do
      assert {:ok, prepared, _details} =
               prepare_with_opts(context, read_only_paths: ["/usr/local/share"])

      args = prepared.invocation.args

      for path <- ["/usr", "/usr/local"] do
        refute Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--dir", path])
      end

      assert Enum.any?(
               Enum.chunk_every(args, 3, 1, :discard),
               &(&1 == ["--ro-bind", "/usr/local/share", "/usr/local/share"])
             )
    end
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
               Alto.Contrib.Command.run(
                 %{"program" => "sh", "args" => ["-c", "touch " <> marker], "timeout_ms" => 100},
                 context,
                 executor: {Bubblewrap, opts}
               )
    end

    refute File.exists?(marker)
  end

  defp prepare_with_opts(%{} = context, opts) do
    healthy = System.find_executable("true") || raise "true executable required"

    Bubblewrap.prepare(invocation(context.cwd), Keyword.put_new(opts, :bubblewrap, healthy))
  end

  defp invocation(cwd) do
    %{
      requested_program: "printf",
      executable: System.find_executable("printf") || "/usr/bin/printf",
      args: ["hello"],
      cwd: cwd,
      timeout_ms: 1_000,
      max_output_bytes: 1_000
    }
  end

  @tag skip: @bwrap_skip
  test "protected workspace paths survive commands while ordinary files remain writable", %{
    root: root,
    context: context
  } do
    git = Path.join(root, ".git")
    File.mkdir!(git)
    File.write!(Path.join(git, "config"), "original")

    assert {:ok, %{exit_status: 0}} =
             Alto.Contrib.Command.run(
               %{
                 "program" => "sh",
                 "args" => [
                   "-c",
                   "printf changed > .git/config; if mv .git/config .git/renamed; then exit 41; fi; rm -rf .git; printf ok > ordinary.txt"
                 ]
               },
               context,
               executor: {Bubblewrap, protected_paths: [".git"]}
             )

    assert File.read!(Path.join(git, "config")) == "original"
    assert File.read!(Path.join(root, "ordinary.txt")) == "ok"

    assert {:ok, %{exit_status: 0}} =
             Alto.Contrib.Command.run(
               %{"program" => "sh", "args" => ["-c", "printf approved > .git/config"]},
               context,
               executor: {Bubblewrap, protected_paths: []}
             )

    assert File.read!(Path.join(git, "config")) == "approved"
  end

  @tag skip: @bwrap_skip
  test "a protected file cannot be removed or renamed inside a writable workspace", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "protected.txt")
    File.write!(path, "original")

    assert {:ok, %{exit_status: 0}} =
             Alto.Contrib.Command.run(
               %{
                 "program" => "sh",
                 "args" => [
                   "-c",
                   "if rm protected.txt; then exit 41; fi; if mv protected.txt moved.txt; then exit 42; fi"
                 ]
               },
               context,
               executor: {Bubblewrap, protected_paths: ["protected.txt"]}
             )

    assert File.read!(path) == "original"
    refute File.exists?(Path.join(root, "moved.txt"))
  end

  @tag skip: @bwrap_skip
  test "protection does not create metadata in a non-repository", %{root: root, context: context} do
    assert {:ok, %{exit_status: 0}} =
             Alto.Contrib.Command.run(%{"program" => "true"}, context,
               executor: {Bubblewrap, protected_paths: [".git"]}
             )

    refute File.exists?(Path.join(root, ".git"))
  end

  test "protected paths cannot escape or alias another location", %{root: root, context: context} do
    File.mkdir!(Path.join(root, "metadata"))
    File.ln_s!("metadata", Path.join(root, ".git"))

    for path <- ["../outside", "/etc", ".", ".git"] do
      assert {:error, {:invalid_protected_path, ^path}} =
               prepare_with_opts(context, protected_paths: [path])
    end
  end
end
