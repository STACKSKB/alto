defmodule Alto.Runner.SupportOwnerTest do
  use ExUnit.Case, async: true

  defmodule BlockingTool do
    @behaviour Alto.Tool

    def name, do: :owner_blocking_tool
    def schema, do: %{parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(_arguments, _context, opts) do
      send(Keyword.fetch!(opts, :owner), {:tool_participant, self()})

      receive do
        :never -> {:ok, :unreachable}
      end
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider

    def describe(_opts), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:provider_participant, self()})

      receive do
        :never -> {:ok, %{message: "unreachable", tool_calls: []}}
      end
    end
  end

  test "hard runner termination kills a supervised serial tool participant" do
    {:ok, handle} =
      Alto.start(%{},
        loop: Alto.rule_loop(steps: ["owner_blocking_tool"]),
        tools: [{BlockingTool, owner: self()}]
      )

    assert_receive {:tool_participant, participant}
    participant_ref = Process.monitor(participant)
    assert {:error, _, _} = Alto.Runner.terminate(handle)
    assert_receive {:DOWN, ^participant_ref, :process, ^participant, :killed}
  end

  test "hard runner termination kills a supervised provider participant" do
    {:ok, handle} = Alto.start("task", provider: {BlockingProvider, owner: self()})

    assert_receive {:provider_participant, participant}
    participant_ref = Process.monitor(participant)
    assert {:error, _, _} = Alto.Runner.terminate(handle)
    assert_receive {:DOWN, ^participant_ref, :process, ^participant, :killed}
  end
end
