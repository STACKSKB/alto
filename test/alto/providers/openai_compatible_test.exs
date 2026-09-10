defmodule Alto.Providers.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Alto.Event
  alias Alto.Providers.OpenAICompatible
  alias Alto.Providers.OpenAICompatible.SSE

  defmodule Adapter do
    def run(request) do
      config = Process.get(:alto_openai_adapter_test)
      send(config.pid, {:http_request, request})

      response =
        Req.Response.new(
          status: config.status,
          headers: [{"content-type", config.content_type}]
        )

      Enum.reduce(config.chunks, {request, response}, fn chunk, acc ->
        case request.into.({:data, chunk}, acc) do
          {:cont, next} -> next
          {:halt, next} -> next
        end
      end)
    end
  end

  test "defaults to OpenRouter" do
    assert OpenAICompatible.describe([]).base_url == "https://openrouter.ai/api/v1"
  end

  test "streams content and reconstructs fragmented function arguments" do
    first =
      sse(%{
        "choices" => [
          %{
            "delta" => %{
              "content" => "Looking ",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call-7",
                  "function" => %{"name" => "read_file", "arguments" => ~s({"path":)}
                }
              ]
            }
          }
        ]
      })

    second =
      sse(%{
        "choices" => [
          %{
            "delta" => %{
              "content" => "now",
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => ~s("README.md"})}}
              ]
            }
          }
        ]
      })

    wire = first <> second <> "data: [DONE]\n\n"
    {left, right} = String.split_at(wire, 17)
    parent = self()
    configure_adapter(parent, 200, "text/event-stream", [left, right])

    assert {:ok, completion} =
             OpenAICompatible.stream(
               %{
                 messages: [%{"role" => "user", "content" => "inspect"}],
                 tools: [
                   %{
                     "type" => "function",
                     "function" => %{"name" => "read_file", "parameters" => %{}}
                   }
                 ]
               },
               fn event -> send(parent, {:event, event}) end,
               model: "test-model",
               base_url: "https://unit.test/v1/",
               api_key: "secret",
               req_options: [adapter: Adapter]
             )

    assert completion.message == "Looking now"

    assert completion.tool_calls == [
             %{id: "call-7", name: "read_file", arguments_json: ~s({"path":"README.md"})}
           ]

    assert_receive {:event, %Event{type: :model_delta, data: %{text: "Looking "}}}
    assert_receive {:event, %Event{type: :model_delta, data: %{text: "now"}}}

    assert_receive {:http_request, request}
    assert request.url.path == "/v1/chat/completions"
    assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]

    body = request.body |> IO.iodata_to_binary() |> JSON.decode!()
    assert body["model"] == "test-model"
    assert body["stream"] == true
    assert body["tool_choice"] == "auto"
  end

  test "returns bounded provider errors" do
    body = JSON.encode!(%{"error" => %{"message" => "bad key"}})
    configure_adapter(self(), 401, "application/json", [body])

    assert {:error, {:http_error, 401, %{"message" => "bad key"}}} =
             OpenAICompatible.stream(
               %{messages: [], tools: []},
               fn _event -> :ok end,
               model: "test-model",
               base_url: "https://unit.test/v1",
               req_options: [adapter: Adapter]
             )
  end

  test "lists and normalizes models from the provider catalog" do
    body =
      JSON.encode!(%{
        "data" => [
          %{
            "id" => "anthropic/claude-sonnet",
            "name" => "Claude Sonnet",
            "context_length" => 200_000,
            "supported_parameters" => ["tools", "reasoning"]
          },
          %{"id" => "openai/gpt", "name" => "GPT"},
          %{"name" => "missing id"}
        ]
      })

    configure_adapter(self(), 200, "application/json", [body])

    assert {:ok, models} =
             OpenAICompatible.list_models(
               base_url: "https://unit.test/v1/",
               api_key: "catalog-secret",
               model_query: [supported_parameters: "tools", sort: "most-popular"],
               req_options: [adapter: Adapter]
             )

    assert models == [
             %{
               id: "anthropic/claude-sonnet",
               name: "Claude Sonnet",
               context_length: 200_000,
               supported_parameters: ["tools", "reasoning"]
             },
             %{
               id: "openai/gpt",
               name: "GPT",
               supported_parameters: []
             }
           ]

    assert_receive {:http_request, request}
    assert request.method == :get
    assert request.url.path == "/v1/models"
    assert request.url.query =~ "supported_parameters=tools"
    assert request.url.query =~ "sort=most-popular"
    assert Req.Request.get_header(request, "authorization") == ["Bearer catalog-secret"]
  end

  test "bounds the provider model catalog" do
    configure_adapter(self(), 200, "application/json", [String.duplicate("x", 32)])

    assert {:error, {:models_response_too_large, 16}} =
             OpenAICompatible.list_models(
               base_url: "https://unit.test/v1",
               max_models_response_bytes: 16,
               req_options: [adapter: Adapter]
             )
  end

  test "stops a stream that exceeds the complete-response limit" do
    payload = sse(%{"choices" => [%{"delta" => %{"content" => "too much"}}]})
    configure_adapter(self(), 200, "text/event-stream", [payload])

    assert {:error, {:model_response_too_large, 10}} =
             OpenAICompatible.stream(
               %{messages: [], tools: []},
               fn _event -> :ok end,
               model: "test-model",
               base_url: "https://unit.test/v1",
               max_response_bytes: 10,
               req_options: [adapter: Adapter]
             )
  end

  test "SSE framing survives CRLF and arbitrary chunk boundaries" do
    state = SSE.new(100)
    assert {:ok, state, []} = SSE.feed(state, "data: one\r")
    assert {:ok, state, ["one"]} = SSE.feed(state, "\n\r\ndata: tw")
    assert {:ok, _state, ["two"]} = SSE.feed(state, "o\n\n")
  end

  test "SSE framing is byte-safe across every boundary in multibyte content" do
    wire = "data: " <> JSON.encode!(%{"text" => "hello 😀 café"}) <> "\r\n\r\n"

    {state, payloads} =
      wire
      |> :binary.bin_to_list()
      |> Enum.reduce({SSE.new(1_000), []}, fn byte, {state, payloads} ->
        assert {:ok, state, emitted} = SSE.feed(state, <<byte>>)
        {state, payloads ++ emitted}
      end)

    assert {:ok, []} = SSE.finish(state)
    assert [payload] = payloads
    assert JSON.decode!(payload) == %{"text" => "hello 😀 café"}
  end

  test "SSE accepts bare CR lines, joins data lines, and removes one optional space" do
    state = SSE.new(100)

    assert {:ok, state, []} =
             SSE.feed(state, "event: message\rdata: first\rdata:   indented\r\r")

    assert {:ok, ["first\n  indented"]} = SSE.finish(state)
  end

  test "non-SSE response fallback preserves raw bytes including blank lines" do
    raw = "{\n\n  \"message\": \"😀\"\n}"
    assert {:ok, state, []} = SSE.feed(SSE.new(100), raw)
    assert {:raw, ^raw} = SSE.finish(state)
  end

  test "SSE bounds an unfinished event across chunks" do
    assert {:ok, state, []} = SSE.feed(SSE.new(12), "data: 123")
    assert {:error, {:sse_event_too_large, 12}} = SSE.feed(state, "4567")
  end

  defp sse(value), do: "data: " <> JSON.encode!(value) <> "\n\n"

  test "merges index-less tool call fragments into one call" do
    first =
      sse(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "id" => "call-9",
                  "function" => %{"name" => "read_file", "arguments" => ~s({"path":)}
                }
              ]
            }
          }
        ]
      })

    second =
      sse(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"function" => %{"arguments" => ~s("README.md"})}}]
            }
          }
        ]
      })

    wire = first <> second <> "data: [DONE]\n\n"
    parent = self()
    configure_adapter(parent, 200, "text/event-stream", [wire])

    assert {:ok, completion} =
             OpenAICompatible.stream(
               %{messages: [%{"role" => "user", "content" => "inspect"}], tools: []},
               fn event -> send(parent, {:event, event}) end,
               model: "test-model",
               base_url: "https://unit.test/v1",
               req_options: [adapter: Adapter]
             )

    assert completion.tool_calls == [
             %{id: "call-9", name: "read_file", arguments_json: ~s({"path":"README.md"})}
           ]
  end

  defp configure_adapter(pid, status, content_type, chunks) do
    Process.put(:alto_openai_adapter_test, %{
      pid: pid,
      status: status,
      content_type: content_type,
      chunks: chunks
    })
  end
end
