defmodule Alto.Tools.TransformTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Tool, as: ExecutionTool
  alias Alto.Tool.Context
  alias Alto.Tools.Transform

  defmodule PreparedTool do
    use Alto.Tool, name: :freeze, execution_mode: :exclusive, approval: :required

    def schema(_), do: %{description: "Freeze input.", parameters: %{type: "object"}}

    def prepare(arguments, _context, _opts) do
      {:ok, {:prepared, arguments}, %{approved: arguments}}
    end

    def run_prepared({:prepared, arguments}, _context, _opts) do
      {:ok, arguments}
    end
  end

  defmodule RawTool do
    use Alto.Tool, name: :raw, execution_mode: :parallel, approval: :never

    def schema(_), do: %{description: "Run transformed input.", parameters: %{type: "object"}}
    def run(arguments, _context, _opts), do: {:ok, arguments}
  end

  defmodule IncompleteTool do
    def prepare(_, _, _), do: raise("must reject incomplete callbacks before preparation")
  end

  test "transforms reject incomplete inner execution contracts before preparation" do
    {_module, opts} = Transform.wrap(IncompleteTool, fn args, _ -> args end)

    assert {:error, {:incomplete_tool_preparation_callbacks, IncompleteTool}} =
             Transform.prepare(%{}, context(), opts)
  end

  defmodule CaptureApproval do
    @behaviour Alto.Approval

    def decide(request, _context, opts) do
      send(Keyword.fetch!(opts, :owner), {:approval, request})
      :approve
    end
  end

  defp context, do: %Context{session_id: "transform-run", cwd: "/tmp", metadata: %{}}

  defp caps(opts) do
    {:ok, budget} = Budget.new(max_model_requests: 10, run_timeout: 30_000)

    %{
      tools: %{},
      approval: Keyword.get(opts, :approval, {Alto.Approvals.DenyAll, []}),
      tool_context: context(),
      budget: budget,
      cancel_ref: nil,
      tool_timeout: 125_000,
      approval_timeout: 300_000,
      max_approval_details_bytes: 64_000,
      max_tool_result_bytes: 64_000,
      event_sink: Keyword.get(opts, :event_sink)
    }
  end

  test "preserves metadata and approves transformed arguments exactly once" do
    parent = self()

    spec =
      Transform.wrap(PreparedTool, fn arguments, context ->
        send(parent, {:transformed, arguments, context.cwd})
        {:ok, Map.put(arguments, "path", Path.join(context.cwd, arguments["path"]))}
      end)

    assert {:ok, tools, _definitions} = Alto.Tool.Registry.build([spec])
    tool = tools["freeze"]
    assert tool.execution_mode == :exclusive
    assert tool.approval == :required

    approval = {CaptureApproval, [owner: parent]}
    caps = caps(approval: approval)
    original = %{"path" => "file.txt"}

    assert {:ok, prepared, details} = ExecutionTool.prepare(tool, original, caps)
    assert details["alto_transformed_arguments"] == %{"path" => "/tmp/file.txt"}
    assert_received {:transformed, ^original, "/tmp"}

    assert :ok =
             ExecutionTool.authorize(
               %{
                 id: "call-1",
                 name: "freeze",
                 arguments: original,
                 tool: tool,
                 op_id: "transform-run:op-1"
               },
               details,
               caps
             )

    assert_received {:approval, request}
    assert request.arguments == original
    assert request.details["alto_transformed_arguments"] == %{"path" => "/tmp/file.txt"}

    assert {:ok, [{:ok, {:ok, %{"path" => "/tmp/file.txt"}}}]} =
             Alto.Runner.ToolBatch.run([{tool, prepared}], caps)

    refute_received {:transformed, _, _}
  end

  test "a stale prepared value runs unchanged and raw tools use wrapper preparation" do
    spec =
      Transform.wrap(PreparedTool, fn args, _context ->
        Map.put(args, "version", args["version"])
      end)

    assert {:ok, prepared_one, _} = Transform.prepare(%{"version" => 1}, context(), elem(spec, 1))

    assert {:ok, _prepared_two, _} =
             Transform.prepare(%{"version" => 2}, context(), elem(spec, 1))

    assert {:ok, %{"version" => 1}} =
             Transform.run_prepared(prepared_one, context(), elem(spec, 1))

    raw_spec = Transform.wrap(RawTool, fn args, _context -> Map.put(args, "normalized", true) end)

    assert {:ok, raw_prepared, %{}} =
             Transform.prepare(%{"value" => 1}, context(), elem(raw_spec, 1))

    assert {:ok, %{"value" => 1, "normalized" => true}} =
             Transform.run_prepared(raw_prepared, context(), elem(raw_spec, 1))
  end

  test "protected-path composition blocks direct and symlink writes while preserving approvals" do
    root = Path.join(System.tmp_dir!(), "alto-protect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "original")
    File.ln_s!(".git", Path.join(root, "alias"))
    on_exit(fn -> File.rm_rf!(root) end)
    context = %Context{session_id: "protect", cwd: root}
    {module, opts} = Alto.Tools.ProtectPaths.wrap(Alto.Tools.WriteFile, [".git"])
    assert module.approval(opts) == :required

    for path <- [".git/config", "alias/config", Path.join(root, ".git/config")] do
      assert {:error, {:protected_path, ^path}} =
               module.prepare(%{"path" => path, "content" => "bad"}, context, opts)
    end

    assert {:ok, prepared, _} =
             module.prepare(%{"path" => ".gitignore", "content" => "ignored"}, context, opts)

    assert {:ok, _} = module.run_prepared(prepared, context, opts)
    assert File.read!(Path.join(root, ".gitignore")) == "ignored"
    assert File.read!(Path.join(root, ".git/config")) == "original"
    {module, opts} = Alto.Tools.ProtectPaths.wrap(Alto.Tools.WriteFile, [])

    assert {:ok, prepared, _} =
             module.prepare(%{"path" => ".git/config", "content" => "explicit"}, context, opts)

    assert {:ok, _} = module.run_prepared(prepared, context, opts)
    assert File.read!(Path.join(root, ".git/config")) == "explicit"
  end
end
