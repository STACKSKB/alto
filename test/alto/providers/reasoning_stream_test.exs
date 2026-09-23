defmodule Alto.Providers.ReasoningStreamTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.OpenAICompatible.Stream

  test "streams readable reasoning once, preserves signatures, and never displays encrypted data" do
    owner = self()
    sink = &send(owner, {:event, &1})

    chunks = [
      %{
        "reasoning" => "Checking ",
        "reasoning_details" => [
          %{"type" => "reasoning.text", "text" => "Checking ", "index" => 0, "signature" => "sig"}
        ]
      },
      %{
        "reasoning" => "files.",
        "reasoning_details" => [
          %{"type" => "reasoning.text", "text" => "files.", "index" => 0, "signature" => "nature"}
        ]
      },
      %{
        "reasoning_details" => [
          %{"type" => "reasoning.encrypted", "data" => "opaque", "index" => 1}
        ]
      },
      %{"content" => "Answer"}
    ]

    stream =
      Enum.reduce(chunks, Stream.new(), fn delta, state ->
        Stream.consume(state, JSON.encode!(%{"choices" => [%{"delta" => delta}]}), sink)
      end)

    assert {:ok, completion} = Stream.result(stream)
    assert completion.message == "Answer"
    assert completion.reasoning == "Checking files."

    assert [%{"text" => "Checking files.", "signature" => "signature"}, %{"data" => "opaque"}] =
             completion.provider_fields["reasoning_details"]

    assert_received {:event, %{type: :model_reasoning_delta, data: %{text: "Checking "}}}
    assert_received {:event, %{type: :model_reasoning_delta, data: %{text: "files."}}}
    refute_received {:event, %{type: :model_reasoning_delta}}
    assert Alto.Reasoning.text(completion.provider_fields) == "Checking files."
  end

  test "reasoning IDs do not reorder signed blocks during replay" do
    delta = %{
      "reasoning_details" => [
        %{"id" => "z", "type" => "reasoning.text", "text" => "first"},
        %{"id" => "a", "type" => "reasoning.encrypted", "data" => "second"}
      ]
    }

    stream =
      Stream.consume(Stream.new(), JSON.encode!(%{"choices" => [%{"delta" => delta}]}), fn _ ->
        :ok
      end)

    assert {:ok, completion} = Stream.result(stream)
    assert Enum.map(completion.provider_fields["reasoning_details"], & &1["id"]) == ["z", "a"]
  end

  test "reasoning detail merge preserves false values and index zero" do
    delta = %{
      "reasoning_details" => [
        %{"index" => 0, "type" => "reasoning.text", "text" => "x", "signature" => true},
        %{"index" => 0, "signature" => false}
      ]
    }

    stream =
      Stream.consume(Stream.new(), JSON.encode!(%{"choices" => [%{"delta" => delta}]}), fn _ ->
        :ok
      end)

    assert {:ok, completion} = Stream.result(stream)

    assert completion.provider_fields["reasoning_details"] ==
             [%{"index" => 0, "type" => "reasoning.text", "text" => "x", "signature" => false}]
  end

  test "JSON fallback and reasoning_content use the same readable event" do
    owner = self()

    message = %{
      "content" => "Answer",
      "reasoning_content" => "Provider explanation",
      "tool_calls" => [
        %{"id" => "z", "function" => %{"name" => "read", "arguments" => ~s({"path":"z"})}},
        %{"id" => "a", "function" => %{"name" => "read", "arguments" => ~s({"path":"a"})}}
      ]
    }

    assert {:ok, stream} =
             Stream.from_response(%{"choices" => [%{"message" => message}]}, &send(owner, &1))

    assert {:ok, result} = Stream.result(stream)
    assert result.message == "Answer"

    assert result.tool_calls == [
             %{id: "z", name: "read", arguments_json: ~s({"path":"z"})},
             %{id: "a", name: "read", arguments_json: ~s({"path":"a"})}
           ]

    assert result.provider_fields["reasoning_content"] == "Provider explanation"
    assert_received %{type: :model_delta, data: %{text: "Answer"}}
    refute_received %{type: :model_delta}
    assert_received %{type: :model_reasoning_delta, data: %{text: "Provider explanation"}}

    assert Alto.Reasoning.text(%{
             "reasoning_details" => [%{"type" => "reasoning.encrypted", "data" => "secret"}]
           }) == ""
  end
end
