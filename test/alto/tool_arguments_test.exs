defmodule Alto.ToolArgumentsTest do
  use ExUnit.Case, async: true

  alias Alto.Runner.Execution.Tool, as: ExecutionTool

  defmodule ContractTool do
    use Alto.Tool, name: :contract, execution_mode: :parallel, approval: :never, arguments: true

    def arguments(_) do
      {"Use a validated value.",
       value: [type: :pos_integer, required: true],
       enabled: [type: :boolean, default: false],
       records: [
         type:
           Alto.Tool.Arguments.list(
             Alto.Tool.Arguments.object(
               label: [type: Alto.Tool.Arguments.text(1, 4), required: true]
             ),
             1,
             2
           )
       ]}
    end

    def run(arguments, context, _) do
      send(context.metadata.owner, {:executed, arguments})
      {:ok, arguments}
    end
  end

  defmodule FrozenTool do
    use Alto.Tool, name: :frozen, execution_mode: :exclusive, approval: :required, arguments: true

    defdelegate arguments(opts), to: ContractTool

    def prepare(arguments, context, _) do
      send(context.metadata.owner, {:prepared, arguments})
      {:ok, {:frozen, arguments}, %{value: arguments["value"]}}
    end

    def run({:frozen, arguments}, context, opts), do: ContractTool.run(arguments, context, opts)
  end

  setup do
    {:ok, budget} = Alto.Runner.Budget.new([])

    caps = %{
      session_id: "contract-test",
      cwd: System.tmp_dir!(),
      metadata: %{owner: self()},
      budget: budget,
      cancel_ref: nil,
      tool_timeout: 5_000,
      max_approval_details_bytes: 64_000,
      max_tool_result_bytes: 64_000
    }

    %{caps: caps}
  end

  test "run-only tools validate before dispatch and receive defaults", %{caps: caps} do
    tool = %{module: ContractTool, opts: []}

    for arguments <- [nil, %{}, %{"value" => 0}, %{"value" => 1, "unexpected" => true}] do
      assert {:error, _} = ExecutionTool.prepare(tool, arguments, caps)
    end

    refute_received {:executed, _}
    assert {:ok, prepared, %{}} = ExecutionTool.prepare(tool, %{"value" => 1}, caps)
    assert {:ok, [{:completed, _}]} = Alto.Runner.ToolBatch.run([{tool, prepared}], caps)
    assert_received {:executed, %{"value" => 1, "enabled" => false}}
  end

  test "nested input errors stay ordinary failures before callbacks", %{caps: caps} do
    tool = %{module: FrozenTool, opts: []}

    for records <- [
          [],
          [nil],
          [%{}],
          [%{"label" => "ok", "extra" => true}],
          [%{"label" => <<255>>}],
          [%{"label" => "😀x"}],
          List.duplicate(%{"label" => "ok"}, 3)
        ] do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExecutionTool.prepare(tool, %{"value" => 1, "records" => records}, caps)
    end

    refute_received {:prepared, _}

    assert {:ok, _, _} =
             ExecutionTool.prepare(tool, %{"value" => 1, "records" => [%{"label" => "😀"}]}, caps)

    assert_received {:prepared, %{"records" => [%{"label" => "😀"}]}}
  end

  test "both delegation entry points validate the shared nested contract", %{caps: caps} do
    for module <- [Alto.Tools.SpawnAgents, Alto.Tools.StartAgents] do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExecutionTool.prepare(
                 %{module: module, opts: []},
                 %{"agents" => [%{"id" => "child", "task" => "missing model selection"}]},
                 caps
               )
    end
  end

  test "transformed input is validated before domain preparation and frozen for execution", %{
    caps: caps
  } do
    {module, opts} =
      Alto.Tool.transform(FrozenTool, fn arguments, _ ->
        Map.update!(arguments, "value", &(&1 + 1))
      end)

    assert {:ok, tools} = Alto.Tool.Registry.build([{module, opts}])
    tool = tools[to_string(module.name(Alto.Tool.configure(module, opts)))]
    assert {:error, _} = ExecutionTool.prepare(tool, %{"value" => -1}, caps)
    refute_received {:prepared, _}

    assert {:ok, prepared, details} = ExecutionTool.prepare(tool, %{"value" => 1}, caps)
    assert details.value == 2
    assert_received {:prepared, %{"value" => 2, "enabled" => false}}
    assert {:ok, [{:completed, _}]} = Alto.Runner.ToolBatch.run([{tool, prepared}], caps)
    assert_received {:executed, %{"value" => 2, "enabled" => false}}
    refute_received {:prepared, _}
  end
end
