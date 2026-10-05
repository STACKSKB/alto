defmodule Alto.Contrib.Providers.StreamEnvelopeTest do
  use ExUnit.Case, async: true

  alias Alto.Contrib.Providers.Anthropic
  alias Alto.Contrib.Providers.OpenAICompatible

  defp run(provider, chunks, extra \\ [], status \\ 200) do
    evidence? = Keyword.get(extra, :evidence, false)
    extra = Keyword.delete(extra, :evidence)
    response_headers = Keyword.get(extra, :response_headers, [])
    extra = Keyword.delete(extra, :response_headers)

    adapter = fn request ->
      Enum.reduce_while(
        chunks,
        {request, Req.Response.new(status: status, headers: response_headers)},
        fn chunk, acc ->
          request.into.({:data, chunk}, acc)
        end
      )
    end

    options =
      Keyword.merge([model: "test", api_key: "secret", req_options: [adapter: adapter]], extra)

    request = %{messages: [%{"role" => "user", "content" => "hello"}], tools: [], options: %{}}

    if provider == :catalog do
      OpenAICompatible.list_models(
        Keyword.put(
          options,
          :max_models_response_bytes,
          options[:max_response_bytes] || 8_000_000
        )
      )
    else
      result = provider.stream(request, fn event -> send(self(), {:event, event}) end, options)

      case result do
        {:error, reason} when not evidence? -> {:error, Alto.Provider.Failure.reason(reason)}
        result -> result
      end
    end
  end

  test "provider streams and catalogs bound all wire bytes" do
    for provider <- [Anthropic, OpenAICompatible, :catalog],
        chunks <- [[":ping\n\n", ":ping\n\n"], ["\n\n\n\n\n\n", "\n\n\n\n\n\n"]] do
      assert {:error, {:provider_response_too_large, 10}} =
               run(provider, chunks, max_response_bytes: 10)
    end
  end

  test "HTTP error bodies obey the same response bound" do
    for provider <- [Anthropic, OpenAICompatible, :catalog] do
      assert {:error, {:provider_response_too_large, 10}} =
               run(provider, ["123456", "789012"], [max_response_bytes: 10], 503)

      assert {:error, {:http_error, 503, "oops"}} =
               run(provider, ["oops"], [max_response_bytes: 10], 503)

      assert {:error, {:http_error, 503, retained}} =
               run(
                 provider,
                 [String.duplicate("x", 32_000), String.duplicate("x", 40_000)],
                 [max_response_bytes: 80_000],
                 503
               )

      assert retained == String.duplicate("x", 64_000)
    end
  end

  test "valid rate limit hints are whitelisted in error metadata" do
    assert {:error, {:http_error, 429, "limited", %{retry_after_ms: 30_000}}} =
             run(
               :catalog,
               [~s({"error":"limited"})],
               [response_headers: [{"Retry-After", "30"}, {"authorization", "private"}]],
               429
             )

    assert {:error,
            {:http_error, 429, %{"metadata" => %{"headers" => _}}, %{retry_after_ms: 30_000}}} =
             run(:catalog, [~s({"error":{"metadata":{"headers":{"Retry-After":"30"}}}})], [], 429)

    assert {:error, {:http_error, 503, "oops"}} = run(:catalog, ["oops"], [], 503)
  end

  test "raw JSON provider errors have the same classification" do
    for provider <- [Anthropic, OpenAICompatible] do
      assert {:error, {:provider_error, %{"code" => 502}}} =
               run(provider, [~s({"error":{"code":502}})])

      assert {:error, {:invalid_provider_response, _}} = run(provider, ["invalid json"])
    end
  end

  test "adapter programming exceptions are not labelled malformed provider requests" do
    for provider <- [Anthropic, OpenAICompatible] do
      options = [
        model: "test",
        api_key: "secret",
        req_options: [adapter: fn _ -> raise "adapter defect" end]
      ]

      assert {:error, {:provider_exception, %RuntimeError{message: "adapter defect"}, _stack}} =
               provider.stream(%{messages: [], tools: []}, fn _ -> :ok end, options)
    end
  end

  test "usage and provenance survive errors later in the same chunk and later chunks" do
    usage =
      "data: " <>
        JSON.encode!(%{
          "id" => "req",
          "model" => "actual",
          "provider" => "route",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 6144, "cost" => 0.0}
        }) <> "\n\n"

    for bad <- ["data: invalid\n\n", "data: {\"error\":{\"message\":\"failed\"}}\n\n"],
        chunks <- [[usage, bad], [usage <> bad]] do
      assert {:error, %Alto.Provider.Failure{} = failure} =
               run(OpenAICompatible, chunks, evidence: true)

      assert failure.usage.input_tokens == 100
      assert failure.usage.output_tokens == 6144

      assert failure.metadata == %{
               request_id: "req",
               model: "actual",
               provider: "route",
               reported_cost: 0.0
             }

      assert failure.diagnostics.response_bytes == byte_size(usage <> bad)
    end
  end

  test "unknown usage stays nil on an error" do
    assert {:error, %Alto.Provider.Failure{usage: nil}} =
             run(OpenAICompatible, ["data: invalid\n\n"], evidence: true)
  end

  test "HTTP failures retain wire diagnostics and only parsed rate limit hints" do
    body = ~s({"error":"limited"})

    for provider <- [Anthropic, OpenAICompatible] do
      assert {:error,
              %Alto.Provider.Failure{
                reason: {:http_error, 429, "limited", %{retry_after_ms: 30_000}},
                usage: nil,
                diagnostics: diagnostics
              }} =
               run(
                 provider,
                 [body],
                 [evidence: true, response_headers: [{"Retry-After", "30"}]],
                 429
               )

      assert diagnostics.response_bytes == byte_size(body)
      assert diagnostics.http_status == 429
      assert diagnostics.events == 0
      assert diagnostics.last_event_ms == nil
    end
  end

  test "heartbeats advance byte arrival without advancing the last SSE event" do
    frame = "data: {\"choices\":[]}\n\n"

    adapter = fn request ->
      {:cont, acc} = request.into.({:data, frame}, {request, Req.Response.new(status: 200)})
      Process.sleep(10)
      {:cont, acc} = request.into.({:data, ":ping\n\n"}, acc)
      acc
    end

    assert {:ok, result} =
             OpenAICompatible.stream(
               %{messages: [], tools: []},
               fn event -> send(self(), {:event, event}) end,
               model: "test",
               req_options: [adapter: adapter]
             )

    assert result.diagnostics.events == 1
    assert result.diagnostics.last_event_ms < result.diagnostics.last_byte_ms

    assert_receive {:event,
                    %Alto.Event{
                      type: :provider_accounting,
                      data: %{diagnostics: %{last_byte_ms: last_byte, last_event_ms: last_event}}
                    }}

    assert last_byte == last_event

    assert_receive {:event,
                    %Alto.Event{
                      type: :provider_accounting,
                      data: %{diagnostics: %{last_byte_ms: last_byte, last_event_ms: last_event}}
                    }}

    assert last_byte > last_event
  end

  test "default stream budget accepts over 2 MB while legacy and event bounds remain enforced" do
    chunk =
      "data: " <>
        JSON.encode!(%{
          "choices" => [%{"delta" => %{"content" => String.duplicate("x", 100_000)}}]
        }) <> "\n\n"

    chunks = List.duplicate(chunk, 21) ++ ["data: [DONE]\n\n"]
    assert {:ok, result} = run(OpenAICompatible, chunks)
    assert byte_size(result.message) == 2_100_000
    assert result.diagnostics.response_bytes > 2_000_000
    assert result.diagnostics.events == 22

    assert {:error,
            %Alto.Provider.Failure{
              reason: {:provider_response_too_large, 2_000_000},
              diagnostics: diagnostics
            }} = run(OpenAICompatible, chunks, evidence: true, max_response_bytes: 2_000_000)

    assert diagnostics.content_bytes == 1_900_000
    assert diagnostics.accepted_bytes < 2_000_000
    assert diagnostics.response_bytes > 2_000_000
    assert diagnostics.max_stream_bytes == 2_000_000

    assert {:error, %Alto.Provider.Failure{reason: {:sse_event_too_large, 100}}} =
             run(OpenAICompatible, [chunk],
               evidence: true,
               max_stream_bytes: 16_000_000,
               max_event_bytes: 100
             )
  end
end
