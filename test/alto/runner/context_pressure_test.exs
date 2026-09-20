defmodule Alto.Runner.ContextPressureTest do
  use ExUnit.Case, async: true

  defmodule Reducer do
    @behaviour Alto.Context.Reducer
    def compact(_, _, opts) do
      send(opts[:owner], :reduced)
      {:ok, %{content: "Earlier work summarized.", data: %{}, events: [], records: []}}
    end
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(opts), do: %{context_window: opts[:window] || 700}

    def stream(request, _, opts) do
      send(opts[:owner], {:sent, request.messages})
      {:ok, %{message: "done", tool_calls: []}}
    end
  end

  defmodule Manual do
    @behaviour Alto.Loop
    def init(_, _),
      do:
        Alto.Transition.continue(nil, [
          Alto.Effect.compact_context(),
          Alto.Effect.request_model(%{})
        ])

    def handle_event(%{type: :model_completed}, state, _), do: Alto.Transition.stop(state, :done)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-pressure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    messages = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => String.duplicate("history", 200)},
      %{"role" => "assistant", "content" => "old answer"}
    ]

    opts = [
      session: :new,
      session_dir: dir,
      resume: %{messages: messages, transcript_bytes: Alto.Context.Transcript.bytes(messages)},
      provider: {Provider, owner: self()},
      compaction: [
        strategy: {Reducer, owner: self()},
        keep_recent_messages: 1,
        max_compactions: 2
      ]
    ]

    %{opts: opts}
  end

  test "model context pressure reduces before dispatch even below the transcript byte cap", %{
    opts: opts
  } do
    assert {:ok, result} = Alto.run("current task", opts)
    assert_receive :reduced
    assert_receive {:sent, messages}
    assert List.last(messages)["content"] == "current task"
    assert Alto.Context.Transcript.bytes(messages) < 700
    assert result.model_requests == 1
    assert Enum.any?(result.events, &(&1.type == :context_compacted))
  end

  test "unresolvable context pressure stops under the configured compaction limit", %{opts: opts} do
    opts = Keyword.put(opts, :provider, {Provider, owner: self(), window: 20})
    assert {:error, {:context_limit, _}, _} = Alto.run("current task", opts)
    refute_receive {:sent, _}, 20
  end

  test "manual reduction is an ordinary loop effect", %{opts: opts} do
    assert {:ok, result} = Alto.run("current task", Keyword.put(opts, :loop, Alto.loop(Manual)))
    assert result.output == :done
    assert_receive :reduced
    assert_receive {:sent, _}
  end

  test "optional threshold reduces before the hard window is reached", %{opts: opts} do
    opts =
      opts
      |> Keyword.put(:provider, {Provider, owner: self(), window: 2_000})
      |> Keyword.put(:loop, Alto.default_loop(context: Alto.Context.window(compact_at: 0.5)))

    assert {:ok, _} = Alto.run("current task", opts)
    assert_receive :reduced
    assert_receive {:sent, messages}
    assert Alto.Context.Transcript.bytes(messages) < 1_000
  end

  test "soft pressure remains advisory when compaction is disabled", %{opts: opts} do
    opts =
      opts
      |> Keyword.put(:provider, {Provider, owner: self(), window: 2_000})
      |> Keyword.put(:loop, Alto.default_loop(context: Alto.Context.window(compact_at: 0.5)))
      |> Keyword.put(:compaction, false)

    assert {:ok, _} = Alto.run("current task", opts)
    refute_receive :reduced, 20
    assert_receive {:sent, _}
  end
end
