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
        Alto.Contrib.run("hello",
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
    assert Alto.Contrib.Retry.Transient.decide({:transport_error, :closed}, 1,
             base_delay: 100,
             max_delay: 150,
             random_source: fn -> 0.5 end
           ) == {:retry, 50, :transport}
  end

  test "jitter remains effective at the exponential delay cap" do
    for {sample, delay} <- [{0.0, 0}, {0.5, 75}, {1.0, 150}] do
      assert {:retry, ^delay, {:http, 503}} =
               Alto.Contrib.Retry.Transient.decide({:http_error, 503, nil}, 4,
                 base_delay: 100,
                 max_delay: 150,
                 random_source: fn -> sample end
               )
    end

    assert {:retry, 150, :transport} =
             Alto.Contrib.Retry.Transient.decide({:transport_error, :closed}, 4,
               base_delay: 100,
               max_delay: 150,
               jitter: false
             )
  end

  test "rate limit hints parse bounded delta, HTTP date, and epoch resets" do
    now_ms = 1_700_000_000_000

    assert %{retry_after_ms: 30_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               [{"Retry-After", "30"}],
               nil,
               now_ms
             )

    assert %{retry_after_ms: 30_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               [],
               %{
                 "metadata" => %{"headers" => %{"retry-after" => "Tue, 14 Nov 2023 22:13:50 GMT"}}
               },
               now_ms
             )

    assert %{rate_limit_reset_ms: 30_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{"X-RateLimit-Reset" => "1700000030"},
               nil,
               now_ms
             )

    assert %{rate_limit_reset_ms: 30_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{"x-ratelimit-reset" => "1700000030000"},
               nil,
               now_ms
             )

    assert is_nil(
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{"retry-after" => String.duplicate("9", 129), "authorization" => "secret"},
               nil,
               now_ms
             )
           )
  end

  test "malformed HTTP hint does not suppress valid body fallback" do
    body = %{"metadata" => %{"headers" => %{"Retry-After" => "30"}}}

    assert %{retry_after_ms: 30_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{"retry-after" => ["invalid"]},
               body,
               0
             )

    assert %{retry_after_ms: 20_000} =
             Alto.Contrib.Retry.Transient.rate_limit_metadata(%{"retry-after" => ["20"]}, body, 0)
  end

  test "malformed timing hints are ignored without exposing unrelated headers" do
    for value <- [<<255>>, String.duplicate("x", 129), %{}, [123], "NaN", "1e999"] do
      assert nil ==
               Alto.Contrib.Retry.Transient.rate_limit_metadata(
                 %{"retry-after" => value},
                 "plain error",
                 1_700_000_000_000
               )
    end

    assert nil ==
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{[{}] => "30", <<255>> => "30"},
               [],
               0
             )

    assert %{rate_limit_reset_ms: 0} ==
             Alto.Contrib.Retry.Transient.rate_limit_metadata(
               %{"x-ratelimit-reset" => "0"},
               nil,
               1_700_000_000_000
             )
  end

  test "server retry minimum cannot be shortened and excessive waits stop" do
    reason = {:http_error, 429, %{}, %{retry_after_ms: 30_000}}

    assert {:retry, 30_000, {:http, 429}} =
             Alto.Contrib.Retry.Transient.decide(reason, 1, random_source: fn -> 0.0 end)

    assert :stop =
             Alto.Contrib.Retry.Transient.decide(
               {:http_error, 429, %{}, %{retry_after_ms: 60_001}},
               1
             )

    assert {:retry, 30_000, {:http, 503}} =
             Alto.Contrib.Retry.Transient.decide(
               {:http_error, 503, nil, %{retry_after_ms: 30_000}},
               1,
               random_source: fn -> 0.0 end
             )
  end

  test "policy defects stop actual retries without logging provider content" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %Alto.Runner.Result{status: :error, reason: :host_transient} =
                 Alto.Contrib.run("secret",
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
