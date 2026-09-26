defmodule Alto.InputTest do
  use ExUnit.Case, async: true

  @receive_timeout 5_000

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:request, request.messages, self()})

      receive do
        :answer -> {:ok, %{message: "answer", tool_calls: []}}
      end
    end
  end

  test "bounded channel retains messages until acknowledged by its sole owner" do
    {:ok, input} = Alto.Input.start_link(max_messages: 2, max_bytes: 5)

    assert {:ok, %{message_id: first}} =
             Alto.Messaging.send(input, text: "one", delivery: :follow_up)

    assert {:ok, %{message_id: second}} = Alto.Messaging.send(input, text: "hi", delivery: :steer)
    assert {:error, :input_capacity} = Alto.Messaging.send(input, text: "x")
    assert {:ok, reader} = Alto.Input.claim(input)
    assert {:error, :input_in_use} = Alto.Input.take(input)
    assert %{message_id: ^second} = Alto.Input.read(input, reader, [:steer])
    assert %{message_id: ^first} = Alto.Input.read(input, reader, [:follow_up])
    assert :ok = Alto.Input.acknowledge(input, reader, second, :consumed)
    assert {:ok, %{status: :consumed}} = Alto.Input.receipt(input, second)
    assert [%{message_id: ^first}] = Alto.Input.list(input)
    assert :ok = Alto.Input.release(input)
    assert {:ok, %{message_id: ^first, text: "one", mode: :follow_up}} = Alto.Input.take(input)
    assert {:ok, %{status: :taken}} = Alto.Input.receipt(input, first)
    assert :empty = Alto.Input.take(input)
    assert {:ok, _} = Alto.Messaging.send(input, text: "12345")
  end

  test "follow-ups continue the same run under the original model budget" do
    {:ok, input} = Alto.Input.start_link()
    opts = [input: input, provider: {Provider, owner: self()}, max_steps: 2]
    {:ok, handle} = Alto.start("first", opts)
    assert_receive {:request, first, worker}, @receive_timeout
    assert List.last(first)["content"] == "first"
    assert {:ok, _} = Alto.Messaging.send(input, text: "second", delivery: :follow_up)
    send(worker, :answer)
    assert_receive {:request, second, next}, @receive_timeout
    assert List.last(second)["content"] == "second"
    assert Enum.any?(second, &(&1["content"] == "answer"))
    assert {:ok, _} = Alto.Messaging.send(input, text: "third", delivery: :follow_up)
    send(next, :answer)
    assert {:error, {:model_step_limit, 2}, result} = Alto.await(handle)
    assert result.model_requests == 2
    assert Enum.count(result.events, &(&1.type == :input_received)) == 2
  end

  test "steering supplied during a provider call arrives at the next safe boundary" do
    {:ok, input} = Alto.Input.start_link()
    {:ok, handle} = Alto.start("first", input: input, provider: {Provider, owner: self()})
    assert_receive {:request, _, worker}, @receive_timeout
    {:ok, _} = Alto.Messaging.send(input, text: "change direction", delivery: :steer)
    refute_receive {:request, _, _}, 20
    send(worker, :answer)
    assert_receive {:request, history, next}, @receive_timeout
    assert List.last(history)["content"] == "change direction"
    send(next, :answer)
    assert {:ok, result} = Alto.await(handle)
    assert result.model_requests == 2
    assert Alto.Input.list(input) == []
  end

  test "two runs cannot consume one channel concurrently" do
    {:ok, input} = Alto.Input.start_link()
    opts = [input: input, provider: {Provider, owner: self()}]
    {:ok, handle} = Alto.start("first", opts)
    assert_receive {:request, _, worker}, @receive_timeout
    assert {:error, :input_in_use, _} = Alto.run("second", opts)
    send(worker, :answer)
    assert {:ok, _} = Alto.await(handle)
    assert {:ok, _reader} = Alto.Input.claim(input)
  end

  test "a rejected transcript insertion leaves the queued message available" do
    {:ok, input} = Alto.Input.start_link()
    {:ok, _} = Alto.Messaging.send(input, text: String.duplicate("x", 1000))

    assert {:error, {:transcript_limit, 500}, _} =
             Alto.run("first",
               input: input,
               provider: {Provider, owner: self()},
               max_transcript_bytes: 500,
               prompt: "system"
             )

    assert length(Alto.Input.list(input)) == 1
    refute_receive {:request, _, _}, 20
  end
end
