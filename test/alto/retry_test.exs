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

  test "transient policy adds deterministic bounded jitter" do
    policy = {Alto.Retry.Transient, base_delay: 100, max_delay: 150, random_source: fn -> 0.5 end}

    assert Alto.Retry.decide(policy, {:transport_error, :closed}, 1) ==
             {:retry, 50, :transport}
  end

  test "jitter remains effective at the exponential delay cap" do
    for {sample, delay} <- [{0.0, 0}, {0.5, 75}, {1.0, 150}] do
      assert {:retry, ^delay, {:http, 503}} =
               Alto.Retry.decide(
                 {Alto.Retry.Transient,
                  base_delay: 100, max_delay: 150, random_source: fn -> sample end},
                 {:http_error, 503, nil},
                 4
               )
    end

    assert {:retry, 150, :transport} =
             Alto.Retry.decide(
               {Alto.Retry.Transient, base_delay: 100, max_delay: 150, jitter: false},
               {:transport_error, :closed},
               4
             )
  end

  defmodule BrokenPolicy do
    def decide(_, _, _), do: raise("sensitive provider content")
  end

  test "policy defects are diagnosed without logging provider content" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :stop = Alto.Retry.decide({BrokenPolicy, []}, :secret, 1)
      end)

    assert log =~ "retry policy failed"
    refute log =~ "sensitive provider content"
    refute log =~ "secret"
  end
end
