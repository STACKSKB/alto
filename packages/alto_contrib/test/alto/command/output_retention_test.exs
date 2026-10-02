defmodule Alto.Contrib.Command.OutputRetentionTest do
  use ExUnit.Case, async: false

  alias Alto.Contrib.Command
  alias Alto.Contrib.Command.Executors.{Bubblewrap, Unsandboxed}
  alias Alto.Contrib.Tools.{ReadFile, RunCommand}

  setup do
    root = Path.join(System.tmp_dir!(), "alto-output-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: %{cwd: root},
      config: [directory: "outputs", max_bytes: 128, max_files: 3]
    }
  end

  defp options(config), do: [executor: {Unsandboxed, output_retention: config}]

  defp command(text, context, config, extra \\ %{}) do
    Command.run(
      Map.merge(%{"program" => "printf", "args" => ["%s", text], "max_output_bytes" => 3}, extra),
      context,
      options(config)
    )
  end

  test "truncated output remains retrievable with ordinary workspace reads", ctx do
    assert {:ok, result} = command("the full command output", ctx.context, ctx.config)
    assert result.truncated
    assert result.output == "put"
    assert %{path: path, bytes: 23, total_bytes: 23, truncated: false} = result.output_retention

    assert {:ok, %{content: "full", next_offset: 8}} =
             Alto.Tool.run(
               ReadFile,
               %{"path" => path, "offset" => 4, "limit" => 4},
               ctx.context
             )

    assert File.read!(Path.join(ctx.root, path)) == "the full command output"
  end

  test "the artifact cap is explicit and preserves binary bytes", ctx do
    config = Keyword.put(ctx.config, :max_bytes, 5)

    assert {:ok, result} =
             Command.run(
               %{
                 "program" => "sh",
                 "args" => ["-c", "printf '\\377abcdef'"],
                 "max_output_bytes" => 2
               },
               ctx.context,
               options(config)
             )

    assert result.encoding == "base64"
    assert %{bytes: 5, total_bytes: 7, truncated: true, path: path} = result.output_retention
    assert File.read!(Path.join(ctx.root, path)) == <<255, "abcd">>
  end

  test "small outputs release their reservations and default execution writes no artifacts",
       ctx do
    assert {:ok, result} =
             Command.run(%{"program" => "printf", "args" => ["abcdef"]}, ctx.context)

    refute Map.has_key?(result, :output_retention)
    assert File.ls!(ctx.root) == []

    for _ <- 1..5 do
      assert {:ok, result} = command("ok", ctx.context, ctx.config)
      refute Map.has_key?(result, :output_retention)
      assert File.ls!(Path.join(ctx.root, "outputs")) == []
    end
  end

  test "concurrent commands cannot exceed the file quota or overwrite reported paths", ctx do
    results =
      1..8
      |> Task.async_stream(fn n -> command("output-#{n}", ctx.context, ctx.config) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    retained = Enum.filter(results, &Map.has_key?(&1.output_retention, :path))
    assert length(retained) == 3
    assert length(Enum.uniq_by(retained, & &1.output_retention.path)) == 3
    assert Enum.count(results, &(&1.output_retention == %{error: :output_retention_full})) == 5
    assert length(File.ls!(Path.join(ctx.root, "outputs"))) == 3

    for result <- retained do
      assert File.read!(Path.join(ctx.root, result.output_retention.path)) =~ "output-"
    end

    before =
      Map.new(
        retained,
        &{&1.output_retention.path, File.read!(Path.join(ctx.root, &1.output_retention.path))}
      )

    assert {:ok, %{output_retention: %{error: :output_retention_full}}} =
             command("later", ctx.context, ctx.config)

    for {path, content} <- before, do: assert(File.read!(Path.join(ctx.root, path)) == content)
  end

  test "preparation and rejected approval do not create files", ctx do
    args = %{"program" => "printf", "args" => ["abcdef"]}
    assert {:ok, prepared} = Command.prepare(args, ctx.context, options(ctx.config))
    assert prepared.approval_details.execution.output_retention.max_files == 3
    refute File.exists?(Path.join(ctx.root, "outputs"))

    assert %{status: :error} =
             Alto.run(args,
               cwd: ctx.root,
               loop: Alto.rule_loop(steps: ["run_command"]),
               tools: [{RunCommand, options(ctx.config)}],
               approval: {:deny, :test}
             )

    assert File.ls!(ctx.root) == []
  end

  test "outside-workspace retention and invalid limits fail before command execution", ctx do
    for config <- [
          [directory: "../escape"],
          [max_bytes: 0],
          [max_files: 0],
          [unknown: true]
        ] do
      assert {:error, _} = command("text", ctx.context, config)
    end

    assert File.ls!(ctx.root) == []
  end

  test "a replaced retention directory is rejected without changing command execution", ctx do
    File.mkdir!(Path.join(ctx.root, "outputs"))
    args = %{"program" => "printf", "args" => ["abcdef"], "max_output_bytes" => 3}
    assert {:ok, prepared} = Command.prepare(args, ctx.context, options(ctx.config))
    File.rmdir!(Path.join(ctx.root, "outputs"))
    File.mkdir!(Path.join(ctx.root, "other"))
    File.ln_s!(Path.join(ctx.root, "other"), Path.join(ctx.root, "outputs"))
    assert {:ok, %{output: "def", output_retention: %{error: _}}} = Command.execute(prepared)
    assert File.ls!(Path.join(ctx.root, "other")) == []
  end

  test "existing slot symlinks are never followed or reused", ctx do
    File.mkdir!(Path.join(ctx.root, "outputs"))
    File.mkdir!(Path.join(ctx.root, "other"))
    File.ln_s!(Path.join(ctx.root, "other"), Path.join(ctx.root, "outputs/slot-1"))

    assert {:ok, %{output_retention: %{error: :output_retention_full}}} =
             command("abcdef", ctx.context, Keyword.put(ctx.config, :max_files, 1))

    assert File.ls!(Path.join(ctx.root, "other")) == []
  end

  test "timeouts retain observed output and nonzero exits retain their status", ctx do
    assert {:ok, result} =
             command("", ctx.context, ctx.config, %{
               "program" => "sh",
               "args" => ["-c", "printf 'before-timeout'; sleep 5"],
               "timeout_ms" => 500
             })

    assert result.timed_out
    assert result.exit_status == nil
    assert File.read!(Path.join(ctx.root, result.output_retention.path)) == "before-timeout"

    assert {:ok, result} =
             command("", ctx.context, ctx.config, %{
               "program" => "sh",
               "args" => ["-c", "printf 'failed' >&2; exit 7"]
             })

    assert result.exit_status == 7
    assert File.read!(Path.join(ctx.root, result.output_retention.path)) == "failed"
  end

  test "failed process startup releases its reservation", ctx do
    assert {:ok, prepared} =
             Command.prepare(
               %{"program" => "printf", "args" => ["abcdef"]},
               ctx.context,
               options(ctx.config)
             )

    prepared = put_in(prepared.execution.executable, Path.join(ctx.root, "absent"))
    assert {:error, {:command_start_failed, _}} = Command.execute(prepared)
    assert File.ls!(Path.join(ctx.root, "outputs")) == []
  end

  @tag skip: not File.dir?("/proc/self/fd")
  test "killing the collector closes its raw artifact descriptor and stops the writer", ctx do
    {pid, ref} =
      spawn_monitor(fn ->
        command("", ctx.context, ctx.config, %{
          "program" => "sh",
          "args" => ["-c", "while :; do printf 'abcdefgh'; sleep 0.01; done"],
          "timeout_ms" => 5_000
        })
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    path =
      eventually(fn ->
        Enum.find(Path.wildcard(Path.join(ctx.root, "outputs/slot-*/*")), fn path ->
          File.stat!(path).size > 0 and open_descriptor?(path)
        end)
      end)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    eventually(fn -> not open_descriptor?(path) end)
    bytes = File.read!(path)
    assert byte_size(bytes) <= ctx.config[:max_bytes]
    Process.sleep(40)
    assert File.read!(path) == bytes
  end

  test "bubblewrap retains the original workspace without adding writable mounts", ctx do
    assert {:ok, invocation} =
             Command.resolve(%{"program" => "printf", "args" => ["abcdef"]}, ctx.context)

    opts = [bubblewrap: System.find_executable("true"), workspace: :read_only]
    assert {:ok, plain, _} = Bubblewrap.prepare(invocation, opts)

    assert {:ok, retained, details} =
             Bubblewrap.prepare(invocation, opts ++ [output_retention: ctx.config])

    assert retained.invocation.cwd == "/"
    assert retained.invocation.args == plain.invocation.args
    assert retained.invocation.output_retention.root == ctx.root
    assert details.workspace == :read_only
    assert details.output_retention.directory == Path.join(ctx.root, "outputs")
    refute File.exists?(Path.join(ctx.root, "outputs"))
  end

  defp open_descriptor?(path) do
    Enum.any?(File.ls!("/proc/self/fd"), fn fd ->
      File.read_link("/proc/self/fd/" <> fd) == {:ok, path}
    end)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: flunk("condition did not become true")

  defp eventually(check, attempts) do
    case check.() do
      value when value not in [false, nil] ->
        value

      _ ->
        Process.sleep(20)
        eventually(check, attempts - 1)
    end
  end
end
