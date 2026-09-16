defmodule Alto.ReasoningTest do
  use ExUnit.Case, async: true
  alias Alto.Reasoning

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

  defmodule Provider do
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:reasoning_request, request})

      {:ok,
       %{
         message: "answer",
         tool_calls: [],
         reasoning: "summary",
         provider_fields: %{
           "reasoning_details" => [
             %{"type" => "reasoning.summary", "summary" => "summary", "index" => 0}
           ],
           "role" => "system"
         }
       }}
    end
  end

  test "reasoning survives a saved conversation and cannot overwrite message roles" do
    dir = Path.join(System.tmp_dir!(), "alto-reasoning-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [provider: {Provider, owner: self()}, tools: [], session: :new, session_dir: dir]
    assert {:ok, first} = Alto.run("hello", opts)
    assert_receive {:reasoning_request, _}
    assert {:ok, _} = Alto.resume(first.session_id, "continue", Keyword.delete(opts, :session))
    assert_receive {:reasoning_request, request}
    assistant = Enum.find(request.messages, &(&1["role"] == "assistant"))
    assert assistant["content"] == "answer"
    assert Alto.Reasoning.text(assistant) == "summary"
  end
end
