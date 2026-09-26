defmodule Alto.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Alto.Tool.Registry

  test "registration rejects invalid metadata and duplicate dynamic names before execution" do
    options = [name: :remote, schema: %{parameters: %{type: "object"}}]

    for invalid <- [[execution_mode: :concurrent], [approval: :sometimes]] do
      assert_raise MatchError, fn -> Registry.build([{Alto.Tools.MCP, options ++ invalid}]) end
    end

    tool = {Alto.Tools.MCP, options}
    assert {:error, {:duplicate_tool, "remote"}} = Registry.build([tool, tool])
  end

  test "name-ordered exposure intersects inherited authority without removing native tools" do
    spec = fn name -> {Alto.Tools.MCP, name: name, schema: %{parameters: %{type: "object"}}} end
    assert {:ok, tools} = Registry.build(Enum.map([:zulu, :alpha, :hidden], spec))

    assert {:ok, definitions, exposure} =
             Registry.expose(tools, nil, MapSet.new(["zulu", "alpha"]))

    assert Enum.map(definitions, & &1["function"]["name"]) == ["alpha", "zulu"]
    assert exposure == MapSet.new(["alpha", "zulu"])
    assert Map.has_key?(tools, "hidden")
    assert {:error, {:unknown_model_tool, "absent"}} = Registry.expose(tools, [:absent], nil)
  end
end
