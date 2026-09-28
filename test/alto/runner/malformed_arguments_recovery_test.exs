defmodule Alto.Runner.MalformedArgumentsRecoveryTest do
  use ExUnit.Case, async: true

  defmodule Tool do
    use Alto.Tool, name: :counter, execution_mode: :parallel, approval: :never

    def schema(_opts),
      do: Alto.Tool.object_schema("Count valid calls", %{value: %{type: :string}}, ["value"])

    def run(%{"value" => value}, _context, opts) do
      send(opts[:owner], {:tool_ran, value})
      {:ok, %{counted: value}}
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}

    def stream(request, _sink, opts) do
      replies = Enum.filter(request.messages, &(&1["role"] == "tool"))
      send(opts[:owner], {:request_replies, replies})

      case {opts[:mode], length(replies)} do
        {:serial, 0} -> {:ok, %{message: nil, tool_calls: [bad("bad-1")]}}
        {:serial, 1} -> {:ok, %{message: nil, tool_calls: [good("good-1")]}}
        {:parallel, 0} -> {:ok, %{message: nil, tool_calls: [bad("bad-1"), good("good-1")]}}
        {_, _} -> {:ok, %{message: "corrected", tool_calls: []}}
      end
    end

    defp bad(id), do: %{id: id, name: "counter", arguments_json: ~s({"value":)}
    defp good(id), do: %{id: id, name: "counter", arguments_json: ~s({"value":"valid"})}
  end

  for mode <- [:serial, :parallel] do
    test "#{mode} malformed arguments settle and allow correction" do
      mode = unquote(mode)

      assert %Alto.Runner.Result{status: :ok, output: "corrected"} =
               result =
               Alto.run("count once",
                 provider: {Provider, owner: self(), mode: mode},
                 tools: [{Tool, owner: self()}]
               )

      assert_receive {:tool_ran, "valid"}
      refute_receive {:tool_ran, _}
      assert Enum.count(result.events, &(&1.type == :tool_failed)) == 1
      assert Enum.count(result.events, &(&1.type == :tool_completed)) == 1
      assert :ok = Alto.Context.Transcript.validate(result.messages)
      assert Enum.count(result.messages, &(&1["role"] == "tool")) == 2
      bad_reply = Enum.find(result.messages, &(&1["tool_call_id"] == "bad-1"))
      assert bad_reply["content"] =~ "Malformed JSON"
      refute bad_reply["content"] =~ ~s({"value":)
      assert Enum.any?(result.messages, &(&1["tool_call_id"] == "good-1"))
    end
  end
end
