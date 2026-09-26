defmodule Alto.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Registry

  test "registration rejects missing callbacks and non-keyword tool options" do
    for spec <- [NonexistentTool, {Alto.Tools.MCP, [:invalid]}] do
      normalized = if is_atom(spec), do: {spec, []}, else: spec
      assert {:error, {:invalid_capability, Alto.Tool, ^normalized}} = Registry.build([spec])
    end
  end

  test "registration rejects invalid metadata and duplicate dynamic names before execution" do
    options = [name: :remote, schema: %{parameters: %{type: "object"}}]

    for invalid <- [[execution_mode: :concurrent], [approval: :sometimes]] do
      assert {:error, {:invalid_tool, _}} =
               Registry.build([{Alto.Tools.MCP, options ++ invalid}])
    end

    tool = {Alto.Tools.MCP, options}
    assert {:error, {:duplicate_tool, "remote"}} = Registry.build([tool, tool])
  end
end
