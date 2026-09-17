defmodule Alto.RetryTest do
  use ExUnit.Case, async: true

  defmodule Policy do
    @behaviour Alto.Retry
    def decide(:host_transient, _attempt, opts) do
      send(opts[:owner], :retry_decided)
      {:retry, 0, :host}
    end
  end

  defmodule Provider do
    def describe(_), do: %{}

    def stream(_request, sink, opts) do
      if opts[:stream], do: sink.(Alto.Event.live(:model_delta, %{text: "partial"}))

      case Agent.get_and_update(opts[:counter], &{&1, &1 + 1}) do
        0 -> {:error, :host_transient}
        _ -> {:ok, %{message: "done", tool_calls: []}}
      end
    end
  end

  test "host policy retries custom errors but cannot replay delivered output" do
    for stream <- [false, true] do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Alto.run("hello",
          provider: {Provider, counter: counter, stream: stream},
          provider_retries: 1,
          retry_policy: {Policy, owner: self()}
        )

      if stream do
        assert {:error, {:model_request_failed, :host_transient}, _} = result
        refute_receive :retry_decided
        assert Agent.get(counter, & &1) == 1
      else
        assert {:ok, _} = result
        assert_receive :retry_decided
        assert Agent.get(counter, & &1) == 2
      end

      Agent.stop(counter)
    end
  end
end
