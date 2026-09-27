defmodule Alto.Session.ChildrenTest do
  use ExUnit.Case, async: true
  alias Alto.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-children-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp child(parent, dir, extra \\ %{}) do
    id = Session.generate_id()

    record =
      Session.started_record(
        Map.merge(
          %{task: "child", subagent: true, parent_session_id: parent, agent_id: "agent-stable"},
          extra
        )
      )

    :ok = Session.append(id, record, session_dir: dir)
    id
  end

  test "discovers old children and grandchildren beyond the recent list, excluding forks", %{
    dir: dir
  } do
    {:ok, parent} = Session.create("parent", %{}, session_dir: dir)
    first = child(parent, dir)
    nested = child(first, dir)
    for n <- 1..105, do: Session.create("unrelated #{n}", %{}, session_dir: dir)
    Session.create("fork", %{parent_session_id: parent}, session_dir: dir)
    File.write!(Path.join(dir, "sess-corrupt.jsonl"), "{partial")

    assert {:ok, %{sessions: children, truncated: false}} =
             Session.Children.list(parent, session_dir: dir)

    assert Enum.sort(Enum.map(children, & &1.id)) == Enum.sort([first, nested])
    assert hd(children).started["agent_id"] == "agent-stable"
  end

  test "bounds returned children and reports truncation", %{dir: dir} do
    {:ok, parent} = Session.create("parent", %{}, session_dir: dir)
    for _ <- 1..257, do: child(parent, dir)

    assert {:ok, %{sessions: children, truncated: true}} =
             Session.Children.list(parent, session_dir: dir)

    assert length(children) == 256

    assert {:error, {:invalid_session_id, _}} =
             Session.Children.list("../escape", session_dir: dir)
  end
end
