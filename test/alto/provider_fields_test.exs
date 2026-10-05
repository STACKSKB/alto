defmodule Alto.ProviderFieldsTest do
  use ExUnit.Case, async: true

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
           "opaque_extension" => %{"value" => "preserved"},
           "content" => "overwritten",
           "tool_calls" => [%{"id" => "injected"}],
           "role" => "system",
           :content => "overwritten by atom key",
           :tool_calls => [%{"id" => "injected"}],
           :role => "system",
           :tool_call_id => "injected",
           :name => "injected"
         }
       }}
    end
  end

  test "opaque provider metadata survives resume without replacing message structure" do
    dir = Path.join(System.tmp_dir!(), "alto-reasoning-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [provider: {Provider, owner: self()}, tools: [], session: :new, session_dir: dir]
    assert %Alto.Runner.Result{status: :ok} = first = Alto.run("hello", opts)
    assert_receive {:reasoning_request, _}

    assert %Alto.Runner.Result{status: :ok} =
             Alto.resume(first.session_id, "continue", Keyword.delete(opts, :session))

    assert_receive {:reasoning_request, request}
    assistant = Enum.find(request.messages, &(&1["role"] == "assistant"))
    assert assistant["content"] == "answer"
    assert assistant["opaque_extension"] == %{"value" => "preserved"}
    refute Map.has_key?(assistant, "tool_calls")
    refute Map.has_key?(assistant, "tool_call_id")
    refute Map.has_key?(assistant, "name")
  end

  defmodule ReasoningProvider do
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      {:ok,
       %{
         message: nil,
         tool_calls: [],
         reasoning: "private reasoning",
         provider_fields: %{"reasoning" => "private reasoning"},
         usage: %{input_tokens: 100, output_tokens: 6144},
         finish_reason: opts[:finish_reason],
         terminal_status: opts[:status]
       }}
    end
  end

  test "reasoning-only exhaustion and incomplete output retain reasoning without returning an answer" do
    for {status, finish} <- [{:exhausted, "length"}, {:incomplete, nil}, {:finished, "stop"}] do
      result =
        Alto.run("task", provider: {ReasoningProvider, status: status, finish_reason: finish})

      assert result.status == :error
      assert result.output == nil

      assert {:reasoning_only_model_response, %{terminal_status: ^status, finish_reason: ^finish}} =
               result.reason

      assert result.usage.output_tokens == 6144
      assert List.last(result.messages)["reasoning"] == "private reasoning"
      assert List.last(result.messages)["content"] == nil
    end
  end
end
