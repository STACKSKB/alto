defmodule Alto.Providers.StreamEnvelopeTest do
  use ExUnit.Case, async: true

  alias Alto.Providers.{Anthropic, OpenAICompatible}

  defp run(provider, chunks, extra \\ [], status \\ 200) do
    adapter = fn request ->
      Enum.reduce_while(chunks, {request, Req.Response.new(status: status)}, fn chunk, acc ->
        request.into.({:data, chunk}, acc)
      end)
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
      provider.stream(request, fn event -> send(self(), {:event, event}) end, options)
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
end
