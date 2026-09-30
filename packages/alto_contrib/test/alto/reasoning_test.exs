defmodule Alto.Contrib.ReasoningTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Reasoning

  test "effort choices are capability-based, including Codex and mandatory reasoning" do
    assert Reasoning.efforts(%{id: "unknown", supported_parameters: ["reasoning"]}) == []

    assert Reasoning.efforts(%{
             efforts: [%{"reasoningEffort" => "high"}, %{"reasoningEffort" => "low"}]
           }) == ["high", "low"]

    assert Reasoning.efforts(%{
             "reasoning" => %{"supported_efforts" => ["none", "high"], "mandatory" => true}
           }) == ["high"]

    assert "max" in Reasoning.efforts(%{reasoning: %{"supported_efforts" => nil}})
    assert Reasoning.efforts(%{reasoning: %{mandatory: true}}) == []
  end
end
