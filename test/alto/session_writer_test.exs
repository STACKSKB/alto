defmodule Alto.SessionWriterTest do
  use ExUnit.Case, async: true
  alias Alto.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-writer-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, opts: [session_dir: dir]}
  end

  test "concurrent callers append complete records exactly once and yield the OS lock", %{
    dir: dir,
    opts: opts
  } do
    {:ok, id} = Session.create("concurrency", %{}, opts)

    results =
      Task.async_stream(
        1..100,
        fn n ->
          Session.append(id, %{"v" => 1, "type" => "probe", "n" => n}, opts)
        end,
        max_concurrency: 12
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, records} = Session.read(id, opts)
    assert Enum.sort(Enum.map(tl(records), & &1["n"])) == Enum.to_list(1..100)
    assert :ok = Session.with_lock(id, opts, fn -> :ok end)
    assert [{pid, _}] = Registry.lookup(Alto.Session.WriterRegistry, {Path.expand(dir), id})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2500
  end

  test "writer death releases ownership and acknowledged records are never replayed", %{
    dir: dir,
    opts: opts
  } do
    {:ok, id} = Session.create("death", %{}, opts)
    [{pid, _}] = Registry.lookup(Alto.Session.WriterRegistry, {Path.expand(dir), id})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert :ok = Session.append(id, %{"v" => 1, "type" => "after_death"}, opts)
    assert {:ok, [%{"type" => "started"}, %{"type" => "after_death"}]} = Session.read(id, opts)
  end

  test "failed opens remain errors and a later append can recover", %{dir: dir, opts: opts} do
    File.mkdir_p!(Path.join(dir, "sess-abc.jsonl"))
    assert {:error, _} = Session.append("sess-abc", %{"v" => 1}, opts)
    File.rmdir!(Path.join(dir, "sess-abc.jsonl"))
    assert :ok = Session.append("sess-abc", %{"v" => 1, "type" => "recovered"}, opts)
    assert {:ok, [%{"type" => "recovered"}]} = Session.read("sess-abc", opts)
  end
end
