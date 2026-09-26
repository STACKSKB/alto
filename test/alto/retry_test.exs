defmodule Alto.RetryTest do
  use ExUnit.Case, async: true

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
    owner = self()

    policy = fn :host_transient, _attempt ->
      send(owner, :retry_decided)
      {:retry, 0, :host}
    end

    for stream <- [false, true] do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Alto.run("hello",
          provider: {Provider, counter: counter, stream: stream},
          provider_retries: 1,
          retry_policy: policy
        )

      if stream do
        assert %Alto.Runner.Result{status: :error, reason: :host_transient} = result
        refute_receive :retry_decided
        assert Agent.get(counter, & &1) == 1
      else
        assert %Alto.Runner.Result{status: :ok} = result
        assert_receive :retry_decided
        assert Agent.get(counter, & &1) == 2
      end

      Agent.stop(counter)
    end
  end

  test "transient policy adds deterministic bounded jitter" do
    assert Alto.Retry.Transient.decide({:transport_error, :closed}, 1,
             base_delay: 100,
             max_delay: 150,
             random_source: fn -> 0.5 end
           ) == {:retry, 50, :transport}
  end

  test "jitter remains effective at the exponential delay cap" do
    for {sample, delay} <- [{0.0, 0}, {0.5, 75}, {1.0, 150}] do
      assert {:retry, ^delay, {:http, 503}} =
               Alto.Retry.Transient.decide({:http_error, 503, nil}, 4,
                 base_delay: 100,
                 max_delay: 150,
                 random_source: fn -> sample end
               )
    end

    assert {:retry, 150, :transport} =
             Alto.Retry.Transient.decide({:transport_error, :closed}, 4,
               base_delay: 100,
               max_delay: 150,
               jitter: false
             )
  end

  test "policy defects stop actual retries without logging provider content" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %Alto.Runner.Result{status: :error, reason: :host_transient} =
                 Alto.run("secret",
                   provider: {Provider, counter: counter},
                   provider_retries: 1,
                   retry_policy: fn _, _ -> raise("sensitive provider content") end
                 )
      end)

    assert Agent.get(counter, & &1) == 1
    assert log =~ "retry policy failed"
    refute log =~ "sensitive provider content"
    refute log =~ "secret"
  end
end
