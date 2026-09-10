defmodule Alto.QueueMatchingTest do
  use ExUnit.Case, async: true

  alias Alto.Queue

  setup do
    dir =
      Path.join(System.tmp_dir!(), "alto-queue-matching-#{System.unique_integer([:positive])}")

    name = String.to_atom("queue_matching_#{System.unique_integer([:positive])}")
    {:ok, _pid} = Queue.start_link(id: "mail", dir: dir, name: name)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: name}
  end

  test "matches beyond unrelated heads while preserving mailbox FIFO", %{name: name} do
    for n <- 1..105, do: Queue.put(name, "other-#{n}", %{"mailbox" => "other", "n" => n})
    Queue.put(name, "a-1", %{"mailbox" => "a", "n" => 1})
    Queue.put(name, "a-2", %{"mailbox" => "a", "n" => 2})

    assert {:ok, [%{key: "a-1"}, %{key: "a-2"}]} =
             Queue.claim_matching(name, %{"mailbox" => "a"}, 2, "worker-a", 100_000)
  end

  test "matches multiple fields exactly, including lists and nil", %{name: name} do
    Queue.put(name, "wrong-number", %{"mailbox" => "a", "kind" => 1.0})
    Queue.put(name, "wrong-list", %{"mailbox" => "a", "kind" => "note", "tags" => ["x"]})
    Queue.put(name, "missing-nil", %{"mailbox" => "a", "kind" => "note"})
    Queue.put(name, "existing-nil", %{"mailbox" => "a", "kind" => "note", "optional" => nil})
    Queue.put(name, "match", %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]})
    Queue.put(name, "later", %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]})

    assert {:ok, [%{key: "match"}]} =
             Queue.claim_matching(
               name,
               %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]},
               1,
               "worker",
               100_000
             )

    assert {:ok, [%{key: "existing-nil"}]} =
             Queue.claim_matching(
               name,
               %{"mailbox" => "a", "optional" => nil},
               1,
               "worker",
               100_000
             )
  end

  test "future matching work does not block later due matching work", %{name: name} do
    now = System.system_time(:millisecond)
    Queue.put(name, "future", %{"mailbox" => "a"}, not_before_ms: now + 60_000)
    Queue.put(name, "due", %{"mailbox" => "a"})

    assert {:ok, [%{key: "due"}]} =
             Queue.claim_matching(name, %{"mailbox" => "a"}, 1, "worker", 100_000)

    assert %{pending: 1, claimed: 1} = Queue.count(name)
  end

  test "matching wire bound sizes the claimed view including owner identity", %{name: name} do
    by = "worker-\"\\\\-東京-" <> String.duplicate("x", 100)
    :sys.replace_state(name, fn state -> %{state | clock: fn -> 10_000 end} end)
    Queue.put(name, "bounded-match", %{"mailbox" => "a"})

    {:ok, [claimed]} = Queue.claim_matching(name, %{"mailbox" => "a"}, 1, by, 100_000)
    size = wire_size(claimed)
    assert :ok = Queue.release(name, claimed.claim_id)

    {:ok, [sized]} = Queue.claim_matching(name, %{"mailbox" => "a"}, 1, by, size + 16)
    exact = wire_size(sized)
    assert :ok = Queue.release(name, sized.claim_id)

    assert {:error, {:record_too_large, _}} =
             Queue.claim_matching(name, %{"mailbox" => "a"}, 1, by, exact - 1)

    assert %{pending: 1, claimed: 0} = Queue.count(name)

    {:ok, [claimed_again]} = Queue.claim_matching(name, %{"mailbox" => "a"}, 1, by, exact)
    assert wire_size(claimed_again) <= size
  end

  test "ordinary bounded claim also sizes the fully claimed view", %{name: name} do
    by = "bounded-\"\\\\-東京-" <> String.duplicate("y", 100)
    :sys.replace_state(name, fn state -> %{state | clock: fn -> 10_000 end} end)
    Queue.put(name, "bounded-ordinary", %{"mailbox" => "a"})

    {:ok, [claimed]} = Queue.claim_bounded(name, 1, by, 100_000)
    size = wire_size(claimed)
    assert :ok = Queue.release(name, claimed.claim_id)

    {:ok, [sized]} = Queue.claim_bounded(name, 1, by, size + 16)
    exact = wire_size(sized)
    assert :ok = Queue.release(name, sized.claim_id)
    assert {:error, {:record_too_large, _}} = Queue.claim_bounded(name, 1, by, exact - 1)
    assert %{pending: 1, claimed: 0} = Queue.count(name)
    assert {:ok, [claimed_again]} = Queue.claim_bounded(name, 1, by, exact)
    assert wire_size(claimed_again) <= size
  end

  test "competing matching claims are fenced and survive restart until lease expiry", %{
    dir: dir,
    name: name
  } do
    {:ok, clock} = Agent.start_link(fn -> 10_000 end)
    now = fn -> Agent.get(clock, & &1) end
    GenServer.stop(name)
    {:ok, _} = Queue.start_link(id: "mail", dir: dir, name: name, clock: now, lease_ms: 100)
    {:ok, _} = Queue.put(name, "a", %{"mailbox" => "a"})
    assert {:ok, [claimed]} = Queue.claim_matching(name, %{"mailbox" => "a"}, 1, "one", 100_000)
    assert {:ok, []} = Queue.claim_matching(name, %{"mailbox" => "a"}, 1, "two", 100_000)

    GenServer.stop(name)
    Agent.update(clock, &(&1 + 100))
    name2 = String.to_atom("queue_matching_restart_#{System.unique_integer([:positive])}")
    {:ok, _} = Queue.start_link(id: "mail", dir: dir, name: name2, clock: now, lease_ms: 100)

    assert {:ok, [reclaimed]} =
             Queue.claim_matching(name2, %{"mailbox" => "a"}, 1, "two", 100_000)

    assert reclaimed.claim_id != claimed.claim_id
    assert {:error, :not_found} = Queue.ack(name2, claimed.claim_id)
  end

  test "byte limit leaves matching record pending", %{name: name} do
    Queue.put(name, "a", %{"mailbox" => "a", "body" => String.duplicate("x", 2_000)})

    assert {:error, {:record_too_large, %{key: "a"}}} =
             Queue.claim_matching(name, %{"mailbox" => "a"}, 1, "worker", 10)

    assert %{pending: 1, claimed: 0} = Queue.count(name)
  end

  test "append failure does not partially claim a matching batch", %{dir: dir} do
    name = String.to_atom("queue_matching_fail_#{System.unique_integer([:positive])}")
    {:ok, _} = Queue.start_link(id: "small", dir: dir, name: name, max_log_bytes: 100_000)
    for key <- ~w(a b c d e f), do: Queue.put(name, key, %{"mailbox" => "a"})
    path = Path.join(dir, "small.jsonl")
    before = File.read!(path)
    :sys.replace_state(name, fn state -> %{state | max_log_bytes: byte_size(before) + 10} end)

    assert {:error, {:queue_write_failed, {:queue_log_too_large, _, max}}} =
             Queue.claim_matching(name, %{"mailbox" => "a"}, 2, "worker", 100_000)

    assert max == byte_size(before) + 10
    assert File.read!(path) == before

    assert %{pending: 6, claimed: 0} = Queue.count(name)
  end

  test "malformed selectors fail before queue state changes", %{name: name} do
    Queue.put(name, "a", %{"mailbox" => "a"})

    assert {:error, :invalid_selector} =
             Queue.claim_matching(name, %{}, 1, "worker", 100_000)

    assert {:error, :invalid_selector} =
             Queue.claim_matching(name, %{"mailbox" => %{bad: true}}, 1, "worker", 100_000)

    assert {:error, :invalid_selector} =
             Queue.claim_matching(
               name,
               %{"mailbox" => String.duplicate("x", 5_000)},
               1,
               "worker",
               100_000
             )

    assert %{pending: 1, claimed: 0} = Queue.count(name)
  end

  defp wire_size(view) do
    [view]
    |> Alto.Protocol.encode_term()
    |> JSON.encode!()
    |> byte_size()
  end
end
