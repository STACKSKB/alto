defmodule Alto.Contrib.Tools.TransformTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Tool, as: ExecutionTool

  defmodule PreparedTool do
    use Alto.Tool, name: :freeze, execution_mode: :exclusive, approval: :required

    def schema(_), do: %{description: "Freeze input.", parameters: %{type: "object"}}

    def prepare(arguments, _context, opts) do
      if opts[:owner], do: send(opts[:owner], {:prepared_opts, opts})
      {:ok, {:prepared, arguments}, %{approved: arguments}}
    end

    def run({:prepared, arguments}, _context, opts) do
      if opts[:owner], do: send(opts[:owner], {:executed_opts, opts})
      {:ok, arguments}
    end
  end

  defmodule RawTool do
    use Alto.Tool, name: :raw, execution_mode: :parallel, approval: :never

    def schema(_), do: %{description: "Run transformed input.", parameters: %{type: "object"}}
    def run(arguments, _context, _opts), do: {:ok, arguments}
  end

  defmodule CaptureApproval do
    def decide(request, _context, opts) do
      send(Keyword.fetch!(opts, :owner), {:approval, request})
      :approve
    end
  end

  defp context, do: %{session_id: "transform-run", cwd: "/tmp", metadata: %{}}

  defp caps(opts) do
    {:ok, budget} = Budget.new(max_model_requests: 10, run_timeout: 30_000)

    %{
      tools: %{},
      approval: Keyword.get(opts, :approval, {:deny, :policy_denied}),
      session_id: "transform-run",
      cwd: "/tmp",
      metadata: %{},
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
      Alto.Tool.transform({PreparedTool, owner: parent}, fn arguments, context ->
        send(parent, {:transformed, arguments, context})
        {:ok, Map.put(arguments, "path", Path.join(context.cwd, arguments["path"]))}
      end)
      |> Alto.Tool.transform(fn arguments, _context ->
        send(parent, {:outer_transform, arguments})
        Map.update!(arguments, "path", &("outer/" <> &1))
      end)

    assert {:ok, tools} = Alto.Tool.Registry.build([spec])
    tool = tools["freeze"]
    assert tool.execution_mode == :exclusive
    assert tool.approval == :required

    approval = fn request, context -> CaptureApproval.decide(request, context, owner: parent) end
    caps = Map.put(caps(approval: approval), :provider, {ExampleProvider, api_key: "private"})
    original = %{"path" => "file.txt"}

    assert {:ok, prepared, details} = ExecutionTool.prepare(tool, original, caps)
    assert details["alto_transformed_arguments"] == %{"path" => "/tmp/outer/file.txt"}
    assert_received {:outer_transform, ^original}
    assert_received {:transformed, %{"path" => "outer/file.txt"}, tool_context}
    assert_received {:prepared_opts, [owner: ^parent]}
    assert %{cwd: "/tmp", session_id: "transform-run", input: nil, messaging: nil} = tool_context
    refute Map.has_key?(tool_context, :provider)
    refute Map.has_key?(tool_context, :approval)

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
    assert request.details["alto_transformed_arguments"] == %{"path" => "/tmp/outer/file.txt"}

    assert {:ok, [{:completed, %{"path" => "/tmp/outer/file.txt"}}]} =
             Alto.Runner.ToolBatch.run([{tool, prepared}], caps)

    assert_received {:executed_opts, [owner: ^parent]}
    refute_received {:outer_transform, _}
    refute_received {:transformed, _, _}
  end

  test "raw tools transform at the shared boundary with map options" do
    spec =
      Alto.Tool.transform({RawTool, %{}}, fn args, _context ->
        Map.put(args, "normalized", true)
      end)

    assert {:ok, tools} = Alto.Tool.Registry.build([spec])
    tool = tools["raw"]
    assert {:ok, prepared, details} = ExecutionTool.prepare(tool, %{"value" => 1}, caps([]))
    assert details["alto_transformed_arguments"] == %{"value" => 1, "normalized" => true}

    assert {:ok, [{:completed, %{"value" => 1, "normalized" => true}}]} =
             Alto.Runner.ToolBatch.run([{tool, prepared}], caps([]))

    {module, opts} = spec

    assert {:ok, %{"value" => 2, "normalized" => true}} =
             Alto.Tool.run(module, %{"value" => 2}, context(), opts)
  end

  test "protected-path composition blocks direct and symlink writes while preserving approvals" do
    root = Path.join(System.tmp_dir!(), "alto-protect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "original")
    File.ln_s!(".git", Path.join(root, "alias"))
    on_exit(fn -> File.rm_rf!(root) end)
    context = %{session_id: "protect", cwd: root}
    {module, opts} = Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.WriteFile, [".git"])
    assert module.approval(opts) == :required

    for path <- [".git/config", "alias/config", Path.join(root, ".git/config")] do
      assert {:error, {:protected_path, ^path}} =
               Alto.Tool.prepare(module, %{"path" => path, "content" => "bad"}, context, opts)
    end

    assert {:ok, prepared, _} =
             Alto.Tool.prepare(
               module,
               %{"path" => ".gitignore", "content" => "ignored"},
               context,
               opts
             )

    assert {:ok, _} = module.run(prepared, context, Alto.Tool.configure(module, opts))
    assert File.read!(Path.join(root, ".gitignore")) == "ignored"
    assert File.read!(Path.join(root, ".git/config")) == "original"
    {module, opts} = Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.WriteFile, [])

    assert {:ok, prepared, _} =
             Alto.Tool.prepare(
               module,
               %{"path" => ".git/config", "content" => "explicit"},
               context,
               opts
             )

    assert {:ok, _} = module.run(prepared, context, Alto.Tool.configure(module, opts))
    assert File.read!(Path.join(root, ".git/config")) == "explicit"
  end
end
