defmodule Alto.Context.ReducerTest do
  use ExUnit.Case, async: true

  defmodule Provider do
    def describe(_), do: %{}

    def stream(request, _sink, opts) do
      send(opts[:owner], {:request, request})
      {:ok, %{message: "brief", tool_calls: [%{name: "must_not_run"}]}}
    end
  end

  defmodule Structured do
    @behaviour Alto.Context.Reducer
    def compact(input, model, opts) do
      send(opts[:owner], {:input, input.middle, input.tools})

      with {:ok, completion} <- model.(%{messages: input.middle, tools: input.tools}) do
        {:ok, %{content: completion.message, data: %{strategy: :custom}, events: [], records: []}}
      end
    end
  end

  test "custom reducers see structured context and retain schemas without executing calls" do
    dir = Path.join(System.tmp_dir!(), "alto-reducer-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, run} =
             Alto.Runner.Execution.Setup.open(String.duplicate("source", 100),
               provider: {Provider, owner: self()},
               tools: [Alto.Tools.ReadFile],
               session: Alto.Session.generate_id(),
               session_dir: dir,
               compaction: [strategy: {Structured, owner: self()}, keep_recent_messages: 1]
             )

    state = Alto.Runner.Execution.Transcript.project(run)

    assert {:ok, state} =
             Alto.Runner.Execution.Transcript.append(state, %{
               "role" => "user",
               "content" => "continue"
             })

    assert {:ok, reduced} = Alto.Runner.Execution.Transcript.reduce(state)
    assert_receive {:input, [_], [_ | _] = tools}
    assert_receive {:request, %{tools: ^tools, tool_choice: :none}}
    assert reduced.model_requests == 1
    assert Enum.any?(reduced.messages_rev, &(&1["content"] == "brief"))
  end
end
