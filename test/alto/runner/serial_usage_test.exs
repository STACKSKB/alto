defmodule Alto.Runner.SerialUsageTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{model: "usage-test"}

    def stream(_request, _sink, _opts) do
      {:ok,
       %{
         message: "done",
         tool_calls: [],
         usage: %{
           "prompt_tokens" => 800,
           "completion_tokens" => 40,
           "prompt_tokens_details" => %{"cached_tokens" => 500}
         }
       }}
    end
  end

  test "provider usage survives into durable events and the final result" do
    assert {:ok, result} = Alto.run("task", loop: Alto.chat_loop(), provider: Provider)

    assert result.usage == %{
             input_tokens: 800,
             output_tokens: 40,
             total_tokens: 840,
             cached_input_tokens: 500,
             last_input_tokens: 800,
             requests: 1
           }

    assert %{usage: %{cached_input_tokens: 500}} =
             Enum.find(result.events, &(&1.type == :model_completed)).data
  end
end
