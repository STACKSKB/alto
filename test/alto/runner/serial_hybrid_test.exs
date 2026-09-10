defmodule Alto.Runner.SerialHybridTest do
  use ExUnit.Case, async: true

  alias Alto.{Effect, Event, Session, Transition}

  defmodule NativeTool do
    @behaviour Alto.Tool
    def name, do: :native
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :parallel
    def approval, do: :never
    def run(arguments, _context), do: {:ok, arguments}
  end

  defmodule NativeModelNativeModelLoop do
    @behaviour Alto.Loop

    def init(_task, _spec),
      do: Transition.continue(%{step: 1}, [native("n1")])

    def handle_event(%Event{type: :tool_completed}, %{step: 1}, _spec),
      do: Transition.continue(%{step: 2}, [Effect.request_model(%{})])

    def handle_event(%Event{type: :model_completed}, %{step: 2}, _spec),
      do: Transition.continue(%{step: 3}, [native("n2")])

    def handle_event(%Event{type: :tool_completed}, %{step: 3}, _spec),
      do: Transition.continue(%{step: 4}, [Effect.request_model(%{})])

    def handle_event(%Event{type: :model_completed, data: %{message: message}}, state, _spec),
      do: Transition.stop(state, message)

    defp native(id),
      do: Effect.invoke_tool(%{id: id, name: "native", arguments: %{"id" => id}})
  end

  defmodule StrictProvider do
    @behaviour Alto.Provider

    def describe(_opts), do: %{}

    def stream(request, _sink, opts) do
      assert_strict_transcript!(request.messages)
      send(Keyword.fetch!(opts, :test_pid), {:strict_messages, request.messages})
      turn = Enum.count(request.messages, &(&1["role"] == "assistant")) + 1
      {:ok, %{message: "model-#{turn}", tool_calls: []}}
    end

    defp assert_strict_transcript!(messages) do
      {_pending, orphan?} =
        Enum.reduce(messages, {%{}, false}, fn
          %{"role" => "assistant", "tool_calls" => calls}, {pending, orphan?} ->
            next = Enum.reduce(calls, pending, &Map.update(&2, &1["id"], 1, fn n -> n + 1 end))
            {next, orphan?}

          %{"role" => "tool", "tool_call_id" => id}, {pending, orphan?} ->
            case Map.get(pending, id, 0) do
              0 -> {pending, true}
              1 -> {Map.delete(pending, id), orphan?}
              count -> {Map.put(pending, id, count - 1), orphan?}
            end

          _message, state ->
            state
        end)

      if orphan?, do: raise("orphan provider tool reply")
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-s14-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "strict provider accepts native/model/native/model and resumed hybrids", %{dir: dir} do
    opts = [
      loop: Alto.loop(NativeModelNativeModelLoop),
      tools: [NativeTool],
      model_tools: [],
      provider: {StrictProvider, test_pid: self()},
      session: :new,
      session_dir: dir
    ]

    assert {:ok, first} = Alto.run("first", opts)
    assert first.output == "model-2"
    assert first.persistence == :ok
    assert native_context_count(first.messages) == 2
    refute Enum.any?(first.messages, &(&1["role"] == "tool"))

    assert {:ok, resumed} =
             Alto.resume(first.session_id, "again", Keyword.drop(opts, [:session]))

    assert resumed.output == "model-4"
    assert resumed.persistence == :ok
    assert native_context_count(resumed.messages) == 4
    refute Enum.any?(resumed.messages, &(&1["role"] == "tool"))

    assert {:ok, %{revision: 2, messages: messages}} =
             Session.transcript(first.session_id, session_dir: dir)

    assert messages == resumed.messages
  end

  defp native_context_count(messages) do
    Enum.count(messages, fn
      %{"role" => "user", "content" => content} ->
        case JSON.decode(content) do
          {:ok, %{"type" => "alto_native_tool_result"}} -> true
          _other -> false
        end

      _message ->
        false
    end)
  end
end
