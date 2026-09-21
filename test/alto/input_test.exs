defmodule Alto.InputTest do
  use ExUnit.Case, async: true

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
    assert {:ok, first} = Alto.Input.put(input, "one", :follow_up)
    assert {:ok, second} = Alto.Input.put(input, "hi", :steer)
    assert {:error, :input_capacity} = Alto.Input.put(input, "x")
    assert :ok = Alto.Input.claim(input)
    assert {:error, :input_in_use} = Alto.Input.take(input)
    assert %{id: ^second} = Alto.Input.peek(input, [:steer])
    assert %{id: ^first} = Alto.Input.peek(input, [:follow_up])
    assert :ok = Alto.Input.ack(input, second)
    assert [%{id: ^first}] = Alto.Input.list(input)
    assert :ok = Alto.Input.release(input)
    assert {:ok, %{id: ^first, text: "one", mode: :follow_up}} = Alto.Input.take(input)
    assert :empty = Alto.Input.take(input)
    assert {:ok, _} = Alto.Input.put(input, "12345")
  end

  test "follow-ups continue the same run under the original model budget" do
    {:ok, input} = Alto.Input.start_link()
    opts = [input: input, provider: {Provider, owner: self()}, max_steps: 2]
    {:ok, handle} = Alto.start("first", opts)
    assert_receive {:request, first, worker}
    assert List.last(first)["content"] == "first"
    assert {:ok, _} = Alto.Input.put(input, "second", :follow_up)
    send(worker, :answer)
    assert_receive {:request, second, next}
    assert List.last(second)["content"] == "second"
    assert Enum.any?(second, &(&1["content"] == "answer"))
    assert {:ok, _} = Alto.Input.put(input, "third", :follow_up)
    send(next, :answer)
    assert {:error, {:model_step_limit, 2}, result} = Alto.await(handle)
    assert result.model_requests == 2
    assert Enum.count(result.events, &(&1.type == :input_received)) == 2
  end

  test "steering supplied during a provider call arrives at the next safe boundary" do
    {:ok, input} = Alto.Input.start_link()
    {:ok, handle} = Alto.start("first", input: input, provider: {Provider, owner: self()})
    assert_receive {:request, _, worker}
    {:ok, _} = Alto.Input.put(input, "change direction", :steer)
    refute_receive {:request, _, _}, 20
    send(worker, :answer)
    assert_receive {:request, history, next}
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
    assert_receive {:request, _, worker}
    assert {:error, :input_in_use, _} = Alto.run("second", opts)
    send(worker, :answer)
    assert {:ok, _} = Alto.await(handle)
    assert :ok = Alto.Input.claim(input)
  end

  test "a rejected transcript insertion leaves the queued message available" do
    {:ok, input} = Alto.Input.start_link()
    {:ok, _} = Alto.Input.put(input, String.duplicate("x", 1000))

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
