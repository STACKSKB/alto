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

  defp configure_stream(events, status \\ 200) do
    wire =
      Enum.map_join(events, "", fn event ->
        "event: " <> event["type"] <> "\ndata: " <> JSON.encode!(event) <> "\n\n"
      end)

    Process.put(:anthropic_test, %{owner: self(), status: status, chunks: String.codepoints(wire)})

    [api_key: "test-secret", model: "configured-model", req_options: [adapter: Adapter]]
  end

  test "enables automatic prefix caching and preserves an explicit override" do
    opts =
      configure(%{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn"
      })

    request = %{messages: [%{"role" => "user", "content" => "hello"}], tools: []}
    assert {:ok, _} = Anthropic.stream(request, fn _ -> :ok end, opts)
    assert_receive {:request, wire}
    assert JSON.decode!(wire.body)["cache_control"] == %{"type" => "ephemeral"}

    assert {:ok, _} =
             Anthropic.stream(request, fn _ -> :ok end, Keyword.put(opts, :prompt_cache, false))

    assert_receive {:request, wire}
    refute Map.has_key?(JSON.decode!(wire.body), "cache_control")

    request =
      Map.put(request, :options, %{"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}})

    assert {:ok, _} = Anthropic.stream(request, fn _ -> :ok end, opts)
    assert_receive {:request, wire}
    assert JSON.decode!(wire.body)["cache_control"]["ttl"] == "1h"
  end

  test "sends typed image tool results as native image sources when vision is enabled" do
    opts =
      configure(%{
        "content" => [%{"type" => "text", "text" => "seen"}],
        "stop_reason" => "end_turn"
      })

    image = Base.encode64(jpeg(12, 9))

    messages = [
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{"id" => "call-image", "function" => %{"name" => "read_image", "arguments" => "{}"}}
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "call-image",
        "content" => [
          %{
            "type" => "image",
            "media_type" => "image/jpeg",
            "data" => image,
            "width" => 12,
            "height" => 9
          }
        ]
      }
    ]

    assert Anthropic.describe(opts).vision == false

    assert {:error, :model_does_not_support_images} =
             Anthropic.stream(%{messages: messages, tools: []}, fn _ -> :ok end, opts)

    refute_received {:request, _}

    vision_opts = Keyword.put(opts, :supports_images, true)
    assert Anthropic.describe(vision_opts).vision == true

    assert {:ok, _completion} =
             Anthropic.stream(%{messages: messages, tools: []}, fn _ -> :ok end, vision_opts)

    assert_receive {:request, request}
    [_assistant, tool_result] = JSON.decode!(request.body)["messages"]

    assert tool_result["content"] == [
             %{
               "type" => "tool_result",
               "tool_use_id" => "call-image",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/jpeg",
                     "data" => image
                   }
                 }
               ]
             }
           ]
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
      %{"type" => "text", "text" => "Checking."},
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

    assert completion.message == "Checking."
    assert_received %{type: :model_delta, data: %{text: "Checking."}}
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

  test "malformed content blocks cannot become successful completions" do
    request = %{messages: [%{"role" => "user", "content" => "go"}], tools: []}

    for block <- [
          %{"type" => "text"},
          %{"type" => "text", "text" => 42},
          %{"type" => "thinking", "thinking" => "hidden"},
          %{"type" => "thinking", "thinking" => "hidden", "signature" => 42},
          %{"type" => "redacted_thinking", "data" => nil},
          %{"type" => "tool_use", "id" => "call", "name" => "echo", "input" => nil},
          %{"type" => "tool_use", "id" => "", "name" => "echo", "input" => %{}}
        ] do
      opts = configure(%{"content" => [block], "stop_reason" => "end_turn"})

      assert {:error, :unsupported_anthropic_content} =
               Anthropic.stream(request, fn _ -> :ok end, opts)
    end
  end

  test "truncated responses cannot become successful completions" do
    request = %{messages: [%{"role" => "user", "content" => "go"}], tools: []}

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

  test "streams text, thinking, usage, and tool JSON incrementally" do
    events = [
      %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 3}}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "inspect "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "first"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "Done"}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "call-1",
          "name" => "read_file",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":)}
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("README.md"})}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 7}
      },
      %{"type" => "message_stop"}
    ]

    opts = configure_stream(events)
    owner = self()

    assert {:ok, completion} =
             Anthropic.stream(%{messages: [], tools: []}, &send(owner, {:event, &1}), opts)

    assert completion.message == "Done"
    assert completion.reasoning == "inspect first"

    assert completion.tool_calls == [
             %{id: "call-1", name: "read_file", arguments_json: ~s({"path":"README.md"})}
           ]

    assert completion.usage == %{"input_tokens" => 3, "output_tokens" => 7}
    assert_received {:event, %Alto.Event{type: :model_reasoning_delta, data: %{text: "inspect "}}}
    assert_received {:event, %Alto.Event{type: :model_reasoning_delta, data: %{text: "first"}}}
    assert_received {:event, %Alto.Event{type: :model_delta, data: %{text: "Done"}}}

    assert completion.provider_fields["alto_anthropic_content"] == [
             %{"type" => "thinking", "thinking" => "inspect first", "signature" => "sig"},
             %{"type" => "text", "text" => "Done"},
             %{
               "type" => "tool_use",
               "id" => "call-1",
               "name" => "read_file",
               "input" => %{"path" => "README.md"}
             }
           ]

    assert_received {:request, request}
    assert JSON.decode!(request.body)["stream"] == true
  end

  test "bounds an unfinished Anthropic SSE event while receiving" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => String.duplicate("x", 100)}
      }
    ]

    opts = configure_stream(events)

    assert {:error, {:sse_event_too_large, 32}} =
             Anthropic.stream(
               %{messages: [], tools: []},
               fn _ -> :ok end,
               Keyword.put(opts, :max_event_bytes, 32)
             )
  end

  test "does not complete tool JSON before a valid final response" do
    events = [
      %{"type" => "message_start", "message" => %{"usage" => %{}}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "call-1",
          "name" => "read_file",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "not-json"}
      },
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "max_tokens"}},
      %{"type" => "message_stop"}
    ]

    assert {:error, {:incomplete_model_response, "max_tokens"}} =
             Anthropic.stream(
               %{messages: [], tools: []},
               fn _ -> :ok end,
               configure_stream(events)
             )
  end

  defp jpeg(width, height) do
    components = <<3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    <<0xFF, 0xD8, 0xFF, 0xC0, 17::16, 8, height::16, width::16, components::binary, 0xFF, 0xD9>>
  end

  test "text-only reduction retains historical tool schemas with native tool choice" do
    opts =
      configure(%{
        "content" => [%{"type" => "text", "text" => "summary"}],
        "stop_reason" => "end_turn"
      })

    tool = %{
      "type" => "function",
      "function" => %{"name" => "read_file", "parameters" => %{"type" => "object"}}
    }

    request = %{
      messages: [%{"role" => "user", "content" => "Summarize"}],
      tools: [tool],
      tool_choice: :none,
      options: %{"tool_choice" => %{"type" => "auto"}}
    }

    assert {:ok, _} = Anthropic.stream(request, fn _ -> :ok end, opts)
    assert_receive {:request, wire}
    body = JSON.decode!(wire.body)
    assert body["tool_choice"] == %{"type" => "none"}
    assert [%{"name" => "read_file"}] = body["tools"]
  end
end
