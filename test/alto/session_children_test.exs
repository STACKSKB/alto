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

  test "cached discovery sees appended, repaired, replaced and removed logs", %{dir: dir} do
    {:ok, parent} = Session.create("parent", %{}, session_dir: dir)
    assert {:ok, %{sessions: []}} = Session.Children.list(parent, session_dir: dir)
    first = child(parent, dir)
    assert {:ok, %{sessions: [%{id: ^first}]}} = Session.Children.list(parent, session_dir: dir)
    nested = child(first, dir)
    assert {:ok, %{sessions: children}} = Session.Children.list(parent, session_dir: dir)
    assert length(children) == 2
    path = Path.join(dir, nested <> ".jsonl")
    original = File.read!(path)
    File.write!(path, "{torn")
    assert {:ok, %{sessions: [_]}} = Session.Children.list(parent, session_dir: dir)
    File.write!(path <> ".replacement", original)
    File.rename!(path <> ".replacement", path)
    assert {:ok, %{sessions: restored}} = Session.Children.list(parent, session_dir: dir)
    assert length(restored) == 2
    File.rm!(Path.join(dir, first <> ".jsonl"))
    assert {:ok, %{sessions: []}} = Session.Children.list(parent, session_dir: dir)
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

  test "persisted headers survive an empty process cache and rebuild after cache corruption", %{
    dir: dir
  } do
    id = child("sess-parent", dir)
    names = [id <> ".jsonl"]

    assert {:reply, [%{id: ^id}] = headers, _} =
             Session.ChildIndex.handle_call({dir, names}, nil, [])

    cache = Path.join([dir, ".cache", "children.json"])
    assert File.exists?(cache)
    assert {:reply, ^headers, _} = Session.ChildIndex.handle_call({dir, names}, nil, [])
    File.write!(cache, "broken")
    assert {:reply, ^headers, _} = Session.ChildIndex.handle_call({dir, names}, nil, [])
    assert {:ok, %{"v" => 1}} = JSON.decode(File.read!(cache))
  end

  test "cached title does not pin the log read buffer", %{dir: dir} do
    id = child("sess-parent", dir, %{task: String.duplicate("task ", 24)})
    path = Path.join(dir, id <> ".jsonl")

    Session.with_lock(id, [session_dir: dir], fn ->
      File.write!(path, String.duplicate(" ", 40_000), [:append])
    end)

    header = Session.Children.header(path)
    assert byte_size(header["task"]) == 120
    assert :binary.referenced_byte_size(header["task"]) < 2000
  end
end
