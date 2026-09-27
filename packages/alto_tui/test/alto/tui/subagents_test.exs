defmodule Alto.TUI.SubagentsTest do
  use ExUnit.Case, async: true

  test "shared-session children report truncation at the inspector limit" do
    dir = Path.join(System.tmp_dir!(), "alto-saved-agents-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, parent} = Alto.Session.create("parent", %{}, session_dir: dir)

    for n <- 1..257 do
      record =
        Alto.Session.started_record(%{
          run_id: "run-#{n}",
          agent_id: "agent-#{n}",
          task: "child",
          subagent: true
        })

      :ok = Alto.Session.append(parent, record, session_dir: dir)
    end

    {agents, warnings} = Alto.TUI.Subagents.load(parent, session_dir: dir)
    assert map_size(agents) == 256
    assert "Saved child history was truncated" in warnings
  end
end
