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
           "input_tokens" => 800,
           "output_tokens" => 40,
           "cached_input_tokens" => 500
         }
       }}
    end
  end

  test "provider usage survives into durable events and the final result" do
    assert %Alto.Runner.Result{status: :ok} =
             result = Alto.run("task", loop: Alto.chat_loop(), provider: Provider)

    assert result.usage == %{
             input_tokens: 800,
             output_tokens: 40,
             total_tokens: 840,
             cached_input_tokens: 500,
             last_input_tokens: 800,
             last_cached_input_tokens: 500,
             context_window: nil,
             requests: 1
           }

    assert %{usage: %{cached_input_tokens: 500}} =
             Enum.find(result.events, &(&1.type == :model_completed)).data
  end

  defmodule FailingProvider do
    def describe(_), do: %{}

    def stream(_, sink, opts) do
      usage = opts[:usage]

      if opts[:timeout] do
        sink.(
          Alto.Event.live(:provider_accounting, %{
            usage: usage,
            metadata: %{request_id: "req", model: "actual"}
          })
        )

        Process.sleep(5_000)
      else
        {:error,
         %Alto.Provider.Failure{
           reason: {:transport_error, :closed},
           usage: usage,
           metadata: %{request_id: "req", model: "actual", provider: "route", reported_cost: 0.0}
         }}
      end
    end
  end

  test "known usage survives provider errors, retries and worker deadlines" do
    usage = %{input_tokens: 100, output_tokens: 6144}

    for timeout? <- [false, true] do
      result =
        Alto.run("task",
          provider: {FailingProvider, usage: usage, timeout: timeout?},
          provider_timeout: 100
        )

      assert result.status == :error
      assert result.usage.output_tokens == 6144
      assert result.usage.requests == 1

      assert [%{usage: %{input_tokens: 100}, metadata: %{request_id: "req", model: "actual"}}] =
               result.provider_attempts
    end

    result =
      Alto.run("task",
        provider: {FailingProvider, usage: usage},
        provider_retries: 1,
        retry_policy: fn _, _ -> {:retry, 0, :test} end
      )

    assert result.usage.output_tokens == 12288
    assert result.usage.requests == 2
    assert length(result.provider_attempts) == 2
    result = Alto.run("task", provider: FailingProvider)
    assert result.usage.requests == 0
    assert [%{usage: nil}] = result.provider_attempts
  end
end
