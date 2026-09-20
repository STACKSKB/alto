defmodule Alto.Runner.SSERetryTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Providers.OpenAICompatible
  alias Alto.Runner.Budget
  alias Alto.Runner.Execution.Model

  defmodule Provider do
    def stream(request, sink, opts) do
      attempt = :atomics.add_get(opts[:counter], 1, 1)
      chunks = if attempt == 1 or opts[:repeat_error], do: opts[:chunks], else: [opts[:success]]
      Process.put(:sse_retry_chunks, chunks)
      send(opts[:parent], {:attempt, request})

      OpenAICompatible.stream(request, sink,
        model: "synthetic",
        req_options: [adapter: Alto.Runner.SSERetryTest.Adapter]
      )
    end
  end

  defmodule Adapter do
    def run(request) do
      response = Req.Response.new(status: 200, headers: [{"content-type", "text/event-stream"}])

      Enum.reduce_while(Process.get(:sse_retry_chunks), {request, response}, fn chunk, acc ->
        request.into.({:data, chunk}, acc)
      end)
    end
  end

  test "retries observed provider_unavailable inside HTTP 200 SSE with the identical request" do
    error = unavailable()
    {outcome, count, request} = run_stream([sse(%{"error" => error})])
    assert {:ok, {:ok, %{message: "done"}}} = outcome
    assert count == 2
    assert_receive {:attempt, ^request}
    assert_receive {:attempt, ^request}
    assert_receive {:event, %Event{type: :model_retry, data: data}}
    assert data == %{step: 1, attempt: 1, max_attempts: 2, kind: {:provider, 502}}
    assert_receive {:event, %Event{type: :model_delta, data: %{text: "done"}}}
    refute_receive {:event, %Event{type: :model_delta}}
  end

  test "invalid and nonretryable SSE errors fail closed" do
    for error <- [
          nil,
          "provider_unavailable",
          %{},
          %{"code" => "502", "metadata" => %{"error_type" => "provider_unavailable"}},
          %{"code" => 502},
          %{"code" => 502, "metadata" => nil},
          %{"code" => 502, "metadata" => %{"error_type" => "invalid_request"}},
          %{"code" => "504", "metadata" => %{"error_type" => "timeout"}},
          %{"code" => 504},
          %{"code" => 504, "metadata" => %{"error_type" => "invalid_request"}},
          %{"code" => 502, "metadata" => %{"error_type" => "timeout"}},
          %{"code" => 400, "metadata" => %{"error_type" => "provider_unavailable"}},
          %{"code" => 401},
          %{"code" => 402}
        ] do
      {outcome, count, _} = run_stream([sse(%{"error" => error})])
      assert outcome == {:ok, {:error, {:provider_error, error}}}
      assert count == 1
      refute_receive {:event, %Event{type: :model_retry}}
    end

    {outcome, count, _} = run_stream(["data: not-json\n\n"])
    assert {:ok, {:error, {:invalid_stream_json, _}}} = outcome
    assert count == 1
    refute_receive {:event, %Event{type: :model_retry}}
  end

  test "never retries after delivering text or reasoning, in one chunk or separate chunks" do
    for field <- ["content", "reasoning"],
        combined <- [true, false],
        failure <- [unavailable(), idle_timeout()] do
      delta = sse(%{"choices" => [%{"delta" => %{field => "partial"}}]})
      error = sse(%{"error" => failure})
      chunks = if combined, do: [delta <> error], else: [delta, error]
      {outcome, count, _} = run_stream(chunks)
      assert outcome == {:ok, {:error, {:provider_error, failure}}}
      assert count == 1
      assert_receive {:event, %Event{data: %{text: "partial"}}}
      refute_receive {:event, %Event{type: :model_retry}}
      refute_receive {:event, %Event{data: %{text: _}}}
    end
  end

  test "retry budget remains opt-in and bounded" do
    {outcome, count, _} = run_stream([sse(%{"error" => unavailable()})], 0)
    assert outcome == {:ok, {:error, {:provider_error, unavailable()}}}
    assert count == 1
    refute_receive {:event, %Event{type: :model_retry}}
  end

  test "retries an empty streamed idle timeout with the identical request" do
    {outcome, count, request} = run_stream([sse(%{"error" => idle_timeout()})])
    assert {:ok, {:ok, %{message: "done"}}} = outcome
    assert count == 2
    assert_receive {:attempt, ^request}
    assert_receive {:attempt, ^request}
    assert_receive {:event, %Event{type: :model_retry, data: %{kind: {:provider, 504}}}}
  end

  test "streamed timeout retries are opt-in and stop at the configured limit" do
    for retries <- [0, 2] do
      {outcome, count, _} = run_stream([sse(%{"error" => idle_timeout()})], retries, true)
      assert outcome == {:ok, {:error, {:provider_error, idle_timeout()}}}
      assert count == retries + 1
    end
  end

  defp unavailable,
    do: %{"code" => 502, "metadata" => %{"error_type" => "provider_unavailable"}}

  defp idle_timeout,
    do: %{"code" => 504, "metadata" => %{"error_type" => "timeout"}}

  defp sse(value), do: "data: " <> JSON.encode!(value) <> "\n\n"

  defp run_stream(chunks, retries \\ 1, repeat_error \\ false) do
    parent = self()
    counter = :atomics.new(1, [])
    {:ok, budget} = Budget.new(max_model_requests: 4, run_timeout: 10_000)
    sink = fn event -> send(parent, {:event, event}) end

    caps = %{
      budget: budget,
      cancel_ref: nil,
      provider_timeout: 2_000,
      provider_retries: retries,
      event_sink: sink,
      retry_policy: nil
    }

    request = %{
      messages: [%{"role" => "user", "content" => "fixed"}],
      tools: [],
      session_id: "fixed"
    }

    success = sse(%{"choices" => [%{"delta" => %{"content" => "done"}}]})

    outcome =
      Model.stream(
        Provider,
        request,
        sink,
        [
          counter: counter,
          chunks: chunks,
          success: success,
          parent: parent,
          repeat_error: repeat_error
        ],
        caps,
        1
      )

    {outcome, :atomics.get(counter, 1), request}
  end
end
