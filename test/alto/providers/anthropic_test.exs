defmodule Alto.Providers.AnthropicTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.Anthropic

  defmodule Adapter do
    def run(request) do
      config = Process.get(:anthropic_test)
      send(config.owner, {:request, request})

      Enum.reduce_while(
        config.chunks,
        {request, Req.Response.new(status: config.status)},
        fn chunk, acc ->
          case request.into.({:data, chunk}, acc) do
            {:cont, next} -> {:cont, next}
            {:halt, next} -> {:halt, next}
          end
        end
      )
    end
  end

  defp configure(body, status \\ 200) do
    wire = JSON.encode!(body)
    <<first::binary-size(7), rest::binary>> = wire
    Process.put(:anthropic_test, %{owner: self(), status: status, chunks: [first, rest]})
    [api_key: "test-secret", model: "configured-model", req_options: [adapter: Adapter]]
  end

  test "native messages carry system policy, tool schemas and correlated tool results" do
    opts =
      configure(%{
        "content" => [
          %{"type" => "text", "text" => "Done"},
          %{
            "type" => "tool_use",
            "id" => "next",
            "name" => "read_file",
            "input" => %{"path" => "next.md"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
      })

    messages = [
      %{"role" => "system", "content" => "Policy"},
      %{"role" => "user", "content" => "Read"},
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "prev",
            "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"a.md\"}"}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "prev", "content" => "Contents"}
    ]

    request = %{
      messages: messages,
      tools: [%{"function" => %{"name" => "read_file", "parameters" => %{"type" => "object"}}}],
      options: %{"max_tokens" => 100, "temperature" => 0}
    }

    owner = self()
    assert {:ok, completion} = Anthropic.stream(request, &send(owner, {:event, &1}), opts)
    assert completion.message == "Done"
    assert [%{id: "next", name: "read_file", arguments_json: args}] = completion.tool_calls
    assert JSON.decode!(args) == %{"path" => "next.md"}
    assert completion.usage["input_tokens"] == 20
    assert_received {:request, http}
    assert http.url.path == "/v1/messages"
    assert Req.Request.get_header(http, "x-api-key") == ["test-secret"]
    body = JSON.decode!(http.body)
    assert body["system"] == "Policy"
    assert body["max_tokens"] == 100
    assert body["temperature"] == 0

    assert List.last(body["messages"])["content"] == [
             %{"type" => "tool_result", "tool_use_id" => "prev", "content" => "Contents"}
           ]

    assert_received {:event, %Alto.Event{type: :model_delta, data: %{text: "Done"}}}
  end

  test "thinking is readable and signed content is replayed unchanged with selected effort" do
    blocks = [
      %{"type" => "thinking", "thinking" => "Check the file", "signature" => "signed"},
      %{"type" => "redacted_thinking", "data" => "opaque"},
      %{
        "type" => "tool_use",
        "id" => "call",
        "name" => "read_file",
        "input" => %{"path" => "README"}
      }
    ]

    opts =
      configure(%{"content" => blocks, "stop_reason" => "tool_use"})
      |> Keyword.put(:reasoning_effort, "high")

    owner = self()

    assert {:ok, completion} =
             Anthropic.stream(%{messages: [], tools: []}, &send(owner, &1), opts)

    assert_received %{type: :model_reasoning_delta, data: %{text: text}}
    assert text =~ "Check the file"
    refute text =~ "opaque"
    assert completion.provider_fields["alto_anthropic_content"] == blocks
    assert_received {:request, request}
    assert JSON.decode!(request.body)["output_config"]["effort"] == "high"

    messages = [
      Map.merge(
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{"id" => "call", "function" => %{"name" => "read_file", "arguments" => "{}"}}
          ]
        },
        completion.provider_fields
      ),
      %{"role" => "tool", "tool_call_id" => "call", "content" => "file contents"}
    ]

    assert {:ok, _} = Anthropic.stream(%{messages: messages, tools: []}, fn _ -> :ok end, opts)
    assert_received {:request, replay}
    assert hd(JSON.decode!(replay.body)["messages"])["content"] == blocks
  end

  test "unknown content and truncated responses cannot silently become successful completions" do
    request = %{messages: [%{"role" => "user", "content" => "go"}], tools: []}

    opts =
      configure(%{
        "content" => [%{"type" => "thinking", "thinking" => "hidden"}],
        "stop_reason" => "end_turn"
      })

    assert {:error, :unsupported_anthropic_content} =
             Anthropic.stream(request, fn _ -> :ok end, opts)

    opts =
      configure(%{
        "content" => [%{"type" => "text", "text" => "Partial"}],
        "stop_reason" => "max_tokens"
      })

    assert {:error, {:incomplete_model_response, "max_tokens"}} =
             Anthropic.stream(request, fn _ -> :ok end, opts)
  end

  test "receiving is bounded and provider error status survives" do
    opts = configure(%{"error" => %{"type" => "overloaded_error"}}, 529)
    request = %{messages: [%{"role" => "user", "content" => "go"}], tools: []}
    assert {:error, {:http_error, 529, _}} = Anthropic.stream(request, fn _ -> :ok end, opts)

    assert {:error, {:model_response_too_large, 10}} =
             Anthropic.stream(
               request,
               fn _ -> :ok end,
               Keyword.put(opts, :max_response_bytes, 10)
             )
  end

  test "unsupported options fail before dispatch" do
    opts = configure(%{"content" => [], "stop_reason" => "end_turn"})
    request = %{messages: [], tools: [], options: %{"unknown_option" => true}}

    assert {:error, {:unsupported_anthropic_options, ["unknown_option"]}} =
             Anthropic.stream(request, fn _ -> :ok end, opts)

    refute_received {:request, _}
  end
end
