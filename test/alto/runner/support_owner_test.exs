defmodule Alto.Runner.SupportOwnerTest do
  use ExUnit.Case, async: true

  defmodule BlockingTool do
    use Alto.Tool, name: :owner_blocking_tool, execution_mode: :exclusive, approval: :never

    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}

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

    assert_receive {:tool_participant, participant}, 3_000
    participant_ref = Process.monitor(participant)
    assert {:error, _, _} = Alto.Runner.terminate(handle)
    assert_receive {:DOWN, ^participant_ref, :process, ^participant, :killed}, 1_000
  end

  test "hard runner termination kills a supervised provider participant" do
    {:ok, handle} = Alto.start("task", provider: {BlockingProvider, owner: self()})

    assert_receive {:provider_participant, participant}, 3_000
    participant_ref = Process.monitor(participant)
    assert {:error, _, _} = Alto.Runner.terminate(handle)
    assert_receive {:DOWN, ^participant_ref, :process, ^participant, :killed}, 1_000
  end
end
