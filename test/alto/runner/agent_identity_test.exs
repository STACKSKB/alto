defmodule Alto.Runner.AgentIdentityTest do
  use ExUnit.Case, async: true

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  defmodule CaptureTool do
    @behaviour Alto.Tool
    def name, do: :capture
    def schema, do: %{description: "capture", parameters: %{type: "object"}}
    def execution_mode, do: :parallel
    def approval, do: :never

    def run(_arguments, context, opts) do
      send(Keyword.fetch!(opts, :owner), {:identity, context.agent_identity})
      {:ok, :captured}
    end
  end

  defmodule SpawnLoop do
    @behaviour Alto.Loop
    def init(%{spawn: request}, _spec),
      do: Transition.continue(%{}, [Effect.spawn_agent(request)])

    def handle_event(%Event{type: :subagent_completed}, state, _spec),
      do: Transition.stop(state, :done)

    def handle_event(_event, state, _spec), do: Transition.continue(state)
  end

  test "nested native tool contexts carry a host-derived identity" do
    request = %{
      id: "child-a",
      task: %{},
      loop: Alto.rule_loop(steps: ["capture"]),
      agent_identity: %{root_run_id: "forged", path: ["forged"]}
    }

    assert {:ok, %{output: :done}} =
             Alto.run(%{spawn: request},
               loop: Alto.loop(SpawnLoop, subagents: Alto.Subagents.bounded(max_depth: 1)),
               tools: [{CaptureTool, owner: self()}]
             )

    assert_receive {:identity, %{root_run_id: root, path: ["child-a"]}}
    assert is_binary(root) and root != "forged"
  end

  test "malformed internal identities fail before any tool executes" do
    for identity <- [
          %{root_run_id: "root", path: [<<255>>]},
          %{root_run_id: String.duplicate("x", 257), path: []},
          %{root_run_id: "root", path: List.duplicate("x", 65)}
        ] do
      assert {:error, {:invalid_option, :agent_identity, ^identity}, _} =
               Alto.run(%{},
                 loop: Alto.rule_loop(steps: ["capture"]),
                 tools: [{CaptureTool, owner: self()}],
                 agent_identity: identity
               )
    end

    assert {:error, {:invalid_option, :agent_identity, _}, _} =
             Alto.run(%{},
               loop: Alto.rule_loop(steps: ["capture"]),
               tools: [{CaptureTool, owner: self()}],
               session_id: <<255>>
             )

    refute_receive {:identity, _}
  end

  test "fresh runs receive distinct root identities" do
    opts = [loop: Alto.rule_loop(steps: ["capture"]), tools: [{CaptureTool, owner: self()}]]
    assert {:ok, _} = Alto.run(%{}, opts)
    assert_receive {:identity, first}
    assert {:ok, _} = Alto.run(%{}, opts)
    assert_receive {:identity, second}
    assert first.path == []
    assert second.path == []
    refute first.root_run_id == second.root_run_id
  end

  test "grandchild native tool context carries the complete delegation path" do
    inner = %{id: "inner", task: %{}, loop: Alto.rule_loop(steps: ["capture"])}

    outer = %{
      id: "outer",
      task: %{spawn: inner},
      loop:
        Alto.loop(SpawnLoop,
          subagents: Alto.Subagents.bounded(max_depth: 2)
        )
    }

    assert {:ok, %{output: :done} = result} =
             Alto.run(%{spawn: outer},
               loop: Alto.loop(SpawnLoop, subagents: Alto.Subagents.bounded(max_depth: 2)),
               tools: [{CaptureTool, owner: self()}]
             )

    assert_receive {:identity, %{root_run_id: root, path: ["outer", "inner"]}}
    assert root == result.run_id
  end

  defmodule CheckpointCaptureTool do
    @behaviour Alto.Tool
    def name, do: :capture_checkpoint
    def schema, do: %{description: "capture", parameters: %{type: "object"}}
    def execution_mode, do: :exclusive
    def prepare(_arguments, context), do: {:ok, :prepared, context.agent_identity}

    def run_prepared(identity, context) do
      send(context.metadata.owner, {:checkpoint_identity, context.agent_identity})
      {:ok, identity}
    end
  end

  test "checkpoint restore preserves identity while minting a new run id" do
    opts = [
      loop: Alto.rule_loop(steps: ["capture_checkpoint"]),
      tools: [CheckpointCaptureTool],
      tool_context_metadata: %{owner: self()},
      approval: Alto.Approvals.Checkpoint,
      checkpoint_version: "identity-test"
    ]

    assert {:error, :approval_suspended, suspended} = Alto.run(%{}, opts)
    summary = suspended.checkpoint["agent_identity"]
    assert summary["root_run_id"] == suspended.agent_identity.root_run_id
    assert summary["path"] == []

    assert {:ok, resumed} =
             Alto.run(%{}, Keyword.put(opts, :checkpoint, {suspended.checkpoint, :approve}))

    assert resumed.agent_identity == suspended.agent_identity
    refute resumed.run_id == suspended.run_id
    assert_receive {:checkpoint_identity, identity}
    assert identity == resumed.agent_identity
  end
end
