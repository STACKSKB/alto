defmodule Alto.Runner.SerialHandoffSteeringTest do
  use ExUnit.Case, async: true

  alias Alto.TestSupport.EchoTool

  @constraints ["KEEP_VECTOR_DATA", "NO_AUTOMATIC_RETRY", "SAVE_SOURCE_ONLY"]

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}

    def stream(request, _sink, opts) do
      reducer? =
        Enum.any?(request.messages, fn message ->
          String.starts_with?(message["content"] || "", "Prepare a context handoff")
        end)

      if reducer? do
        send(opts[:owner], {:handoff_request, request})
        encoded = JSON.encode!(request.messages)
        constraints = Enum.filter(opts[:constraints], &String.contains?(encoded, &1))

        {:ok,
         %{
           message:
             JSON.encode!(%{
               design: Enum.join(constraints, "\n"),
               pointers: "Retained echo tool results.",
               handoff: "Work remains in progress.",
               next_step: "Continue under the retained constraints."
             }),
           tool_calls: []
         }}
      else
        send(opts[:owner], {:work_request, request, self()})

        receive do
          {:complete, completion} -> {:ok, completion}
        end
      end
    end
  end

  test "accepted steers survive repeated real Handoff compactions exactly once with correlated tools" do
    dir = Path.join(System.tmp_dir!(), "alto-handoff-steer-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, input} = Alto.Input.start_link()
    [initial, first, second] = @constraints
    second_steer = second <> "\n" <> String.duplicate("steering rationale ", 18)

    assert {:ok, %{message_id: first_id}} =
             Alto.Messaging.send(input, text: first, delivery: :steer, idempotency_key: "first")

    assert {:ok, handle} =
             Alto.start(initial <> "\n" <> String.duplicate("initial context ", 100),
               input: input,
               provider: {Provider, owner: self(), constraints: @constraints},
               tools: [EchoTool],
               session: :new,
               session_dir: dir,
               max_transcript_bytes: 2500,
               compaction: [
                 strategy: {Alto.Context.Reducers.Handoff, []},
                 max_compactions: 5,
                 keep_recent_messages: 1,
                 max_handoff_bytes: 500,
                 artifact_dir: Path.join(dir, "h")
               ]
             )

    assert_receive {:work_request, request1, worker1}, 5000
    assert count_content(request1.messages, first) == 1

    assert {:ok, %{message_id: second_id}} =
             Alto.Messaging.send(input,
               text: second_steer,
               delivery: :steer,
               idempotency_key: "second"
             )

    send(worker1, {:complete, tool_call("work-1")})

    assert_receive {:work_request, request2, worker2}, 5000
    assert count_content(request2.messages, second_steer) == 1
    assert JSON.encode!(request2.messages) =~ first
    assert :ok = Alto.Context.Transcript.validate(request2.messages)
    assert_tool_pair(request2.messages, "work-1")
    send(worker2, {:complete, tool_call("work-2")})

    assert_receive {:work_request, request3, worker3}, 5000
    for constraint <- @constraints, do: assert(JSON.encode!(request3.messages) =~ constraint)
    assert :ok = Alto.Context.Transcript.validate(request3.messages)
    assert_tool_pair(request3.messages, "work-2")
    send(worker3, {:complete, tool_call("work-3", 100)})
    assert_receive {:work_request, request4, worker4}, 5000
    for constraint <- @constraints, do: assert(JSON.encode!(request4.messages) =~ constraint)
    assert :ok = Alto.Context.Transcript.validate(request4.messages)
    assert_tool_pair(request4.messages, "work-3")
    send(worker4, {:complete, %{message: "done", tool_calls: []}})
    assert %Alto.Runner.Result{status: :ok, output: "done"} = result = Alto.await(handle)

    compacted = Enum.filter(result.events, &(&1.type == :context_compacted))
    assert length(compacted) >= 2
    assert Enum.all?(compacted, &(&1.data.strategy == :handoff))
    assert :ok = Alto.Context.Transcript.validate(result.messages)

    reducer_requests =
      for _ <- compacted do
        assert_receive {:handoff_request, request}, 5000
        assert :ok = Alto.Context.Transcript.validate(Enum.drop(request.messages, -1))
        request
      end

    assert JSON.encode!(hd(reducer_requests).messages) =~ initial
    assert JSON.encode!(hd(reducer_requests).messages) =~ first

    for constraint <- @constraints,
        do: assert(JSON.encode!(List.last(reducer_requests).messages) =~ constraint)

    received = Enum.filter(result.events, &(&1.type == :input_received))
    assert Enum.map(received, & &1.data.message_id) == [first_id, second_id]
    assert Alto.Input.request(input, :list) == []

    for id <- [first_id, second_id] do
      assert {:ok, %{status: :consumed}} = Alto.Input.request(input, {:receipt, id})
    end

    assert Enum.map(Enum.filter(result.events, &(&1.type == :tool_completed)), & &1.data.call_id) ==
             ["work-1", "work-2", "work-3"]

    refute_receive {:work_request, _, _}
    refute_receive {:handoff_request, _}
  end

  defp tool_call(id, repeats \\ 150) do
    %{
      message: nil,
      tool_calls: [
        %{
          id: id,
          name: "echo",
          arguments_json: JSON.encode!(%{value: String.duplicate("work", repeats)})
        }
      ]
    }
  end

  defp count_content(messages, text), do: Enum.count(messages, &(&1["content"] == text))

  defp assert_tool_pair(messages, id) do
    assert Enum.count(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == id)) == 1
    calls = Enum.flat_map(messages, &(&1["tool_calls"] || []))
    assert Enum.count(calls, &(&1["id"] == id)) == 1
  end
end
