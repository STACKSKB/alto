defmodule Alto.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Registry

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
