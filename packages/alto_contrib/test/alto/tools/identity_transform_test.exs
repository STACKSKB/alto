defmodule Alto.Contrib.Tools.IdentityTransformTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Tool, as: ExecutionTool

  test "identity protected-path transform does not duplicate large write input in approval details" do
    root =
      Path.join(
        System.tmp_dir!(),
        "alto-identity-transform-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {module, opts} = Alto.Contrib.Tools.ProtectPaths.wrap(Alto.Contrib.Tools.WriteFile, [])
    assert {:ok, tools} = Alto.Tool.Registry.build([{module, opts}])
    tool = tools["write_file"]
    context = %{session_id: "identity-transform", cwd: root, metadata: %{}}
    {:ok, budget} = Budget.new(max_model_requests: 10, run_timeout: 30_000)

    caps = %{
      session_id: context.session_id,
      cwd: root,
      metadata: %{},
      budget: budget,
      cancel_ref: nil,
      tool_timeout: 30_000,
      max_approval_details_bytes: 64_000
    }

    content = String.duplicate("large protected-path write\n", 4_000)
    arguments = %{"path" => "large.txt", "content" => content}

    assert {:ok, prepared, details} = ExecutionTool.prepare(tool, arguments, caps)
    assert :erlang.external_size(details) <= caps.max_approval_details_bytes
    refute Map.has_key?(details, "alto_transformed_arguments")

    assert {:ok, _result} = module.run(prepared, context, Alto.Tool.configure(module, opts))
    assert File.read!(Path.join(root, "large.txt")) == content
  end
end
