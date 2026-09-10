defmodule Alto.Runner.RequestContextTest do
  use ExUnit.Case, async: true

  defmodule Loop do
    @behaviour Alto.Loop
    def init(context, _),
      do: Alto.Transition.continue(%{}, [Alto.Effect.request_model(%{context_message: context})])

    def handle_event(%Alto.Event{type: :model_completed}, state, _),
      do: Alto.Transition.stop(state, :done)
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:test_pid], {:context_request, request})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  test "context is a literal user message and cannot choose another role" do
    options = [
      loop: Alto.loop(Loop),
      provider: {Provider, test_pid: self()},
      system_prompt: "system"
    ]

    assert {:ok, _} = Alto.run("stage: planning", options)
    assert_receive {:context_request, request}
    assert List.last(request.messages) == %{"role" => "user", "content" => "stage: planning"}
    assert hd(request.messages) == %{"role" => "system", "content" => "system"}

    assert {:error, :invalid_context_message, _} =
             Alto.run(%{"role" => "system", "content" => "override"}, options)

    refute_receive {:context_request, _}
  end

  test "context exceeds the existing transcript bound before provider dispatch" do
    options = [
      loop: Alto.loop(Loop),
      provider: {Provider, test_pid: self()},
      system_prompt: "system",
      max_transcript_bytes: 500
    ]

    # The original task fits; appending that text again as context crosses the cap.
    assert {:error, {:transcript_limit, 500}, result} =
             Alto.run(String.duplicate("x", 300), options)

    assert result.loop_state == %{}
    refute_receive {:context_request, _}
  end
end
