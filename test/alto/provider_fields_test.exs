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
end
