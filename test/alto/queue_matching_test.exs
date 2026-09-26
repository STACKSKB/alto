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
    for n <- 1..105,
        do: Queue.request(name, {:put, "other-#{n}", %{"mailbox" => "other", "n" => n}, []})

    Queue.request(name, {:put, "a-1", %{"mailbox" => "a", "n" => 1}, []})
    Queue.request(name, {:put, "a-2", %{"mailbox" => "a", "n" => 2}, []})

    assert {:ok, [%{key: "a-1"}, %{key: "a-2"}]} =
             Queue.request(name, {:claim, 2, "worker-a", 100_000, %{"mailbox" => "a"}})
  end

  test "matches multiple fields exactly, including lists and nil", %{name: name} do
    Queue.request(name, {:put, "wrong-number", %{"mailbox" => "a", "kind" => 1.0}, []})

    Queue.request(
      name,
      {:put, "wrong-list", %{"mailbox" => "a", "kind" => "note", "tags" => ["x"]}, []}
    )

    Queue.request(name, {:put, "missing-nil", %{"mailbox" => "a", "kind" => "note"}, []})

    Queue.request(
      name,
      {:put, "existing-nil", %{"mailbox" => "a", "kind" => "note", "optional" => nil}, []}
    )

    Queue.request(
      name,
      {:put, "match", %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]}, []}
    )

    Queue.request(
      name,
      {:put, "later", %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]}, []}
    )

    assert {:ok, [%{key: "match"}]} =
             Queue.request(
               name,
               {:claim, 1, "worker", 100_000,
                %{"mailbox" => "a", "kind" => "note", "tags" => ["x", "y"]}}
             )

    assert {:ok, [%{key: "existing-nil"}]} =
             Queue.request(
               name,
               {:claim, 1, "worker", 100_000, %{"mailbox" => "a", "optional" => nil}}
             )
  end

  test "future matching work does not block later due matching work", %{name: name} do
    now = System.system_time(:millisecond)
    Queue.request(name, {:put, "future", %{"mailbox" => "a"}, [not_before_ms: now + 60_000]})
    Queue.request(name, {:put, "due", %{"mailbox" => "a"}, []})

    assert {:ok, [%{key: "due"}]} =
             Queue.request(name, {:claim, 1, "worker", 100_000, %{"mailbox" => "a"}})

    assert %{pending: 1, claimed: 1} = Queue.request(name, :count)
  end

  test "matching wire bound sizes the claimed view including owner identity", %{name: name} do
    by = "worker-\"\\\\-東京-" <> String.duplicate("x", 100)
    :sys.replace_state(name, fn state -> %{state | clock: fn -> 10_000 end} end)
    Queue.request(name, {:put, "bounded-match", %{"mailbox" => "a"}, []})

    {:ok, [claimed]} = Queue.request(name, {:claim, 1, by, 100_000, %{"mailbox" => "a"}})
    size = wire_size(claimed)
    assert :ok = Queue.request(name, {:settle, claimed.claim_id, :release, []})

    {:ok, [sized]} = Queue.request(name, {:claim, 1, by, size + 16, %{"mailbox" => "a"}})
    exact = wire_size(sized)
    assert :ok = Queue.request(name, {:settle, sized.claim_id, :release, []})

    assert {:error, {:record_too_large, _}} =
             Queue.request(name, {:claim, 1, by, exact - 1, %{"mailbox" => "a"}})

    assert %{pending: 1, claimed: 0} = Queue.request(name, :count)

    {:ok, [claimed_again]} = Queue.request(name, {:claim, 1, by, exact, %{"mailbox" => "a"}})
    assert wire_size(claimed_again) <= size
  end

  test "ordinary bounded claim also sizes the fully claimed view", %{name: name} do
    by = "bounded-\"\\\\-東京-" <> String.duplicate("y", 100)
    :sys.replace_state(name, fn state -> %{state | clock: fn -> 10_000 end} end)
    Queue.request(name, {:put, "bounded-ordinary", %{"mailbox" => "a"}, []})

    {:ok, [claimed]} = Queue.request(name, {:claim, 1, by, 100_000, :all})
    size = wire_size(claimed)
    assert :ok = Queue.request(name, {:settle, claimed.claim_id, :release, []})

    {:ok, [sized]} = Queue.request(name, {:claim, 1, by, size + 16, :all})
    exact = wire_size(sized)
    assert :ok = Queue.request(name, {:settle, sized.claim_id, :release, []})

    assert {:error, {:record_too_large, _}} =
             Queue.request(name, {:claim, 1, by, exact - 1, :all})

    assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
    assert {:ok, [claimed_again]} = Queue.request(name, {:claim, 1, by, exact, :all})
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
    {:ok, _} = Queue.request(name, {:put, "a", %{"mailbox" => "a"}, []})

    assert {:ok, [claimed]} =
             Queue.request(name, {:claim, 1, "one", 100_000, %{"mailbox" => "a"}})

    assert {:ok, []} = Queue.request(name, {:claim, 1, "two", 100_000, %{"mailbox" => "a"}})

    GenServer.stop(name)
    Agent.update(clock, &(&1 + 100))
    name2 = String.to_atom("queue_matching_restart_#{System.unique_integer([:positive])}")
    {:ok, _} = Queue.start_link(id: "mail", dir: dir, name: name2, clock: now, lease_ms: 100)

    assert {:ok, [reclaimed]} =
             Queue.request(name2, {:claim, 1, "two", 100_000, %{"mailbox" => "a"}})

    assert reclaimed.claim_id != claimed.claim_id
    assert {:error, :not_found} = Queue.request(name2, {:settle, claimed.claim_id, :ack, []})
  end

  test "byte limit leaves matching record pending", %{name: name} do
    Queue.request(
      name,
      {:put, "a", %{"mailbox" => "a", "body" => String.duplicate("x", 2_000)}, []}
    )

    assert {:error, {:record_too_large, %{key: "a"}}} =
             Queue.request(name, {:claim, 1, "worker", 10, %{"mailbox" => "a"}})

    assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
  end

  test "append failure does not partially claim a matching batch", %{dir: dir} do
    name = String.to_atom("queue_matching_fail_#{System.unique_integer([:positive])}")
    {:ok, _} = Queue.start_link(id: "small", dir: dir, name: name, max_log_bytes: 100_000)
    for key <- ~w(a b c d e f), do: Queue.request(name, {:put, key, %{"mailbox" => "a"}, []})
    path = Path.join(dir, "small.jsonl")
    before = File.read!(path)
    :sys.replace_state(name, fn state -> %{state | max_log_bytes: byte_size(before) + 10} end)

    assert {:error, {:queue_write_failed, {:queue_log_too_large, _, max}}} =
             Queue.request(name, {:claim, 2, "worker", 100_000, %{"mailbox" => "a"}})

    assert max == byte_size(before) + 10
    assert File.read!(path) == before

    assert %{pending: 6, claimed: 0} = Queue.request(name, :count)
  end

  test "malformed selectors fail before queue state changes", %{name: name} do
    Queue.request(name, {:put, "a", %{"mailbox" => "a"}, []})

    assert {:error, :invalid_selector} =
             Queue.request(name, {:claim, 1, "worker", 100_000, %{}})

    assert {:error, :invalid_selector} =
             Queue.request(name, {:claim, 1, "worker", 100_000, %{"mailbox" => %{bad: true}}})

    assert {:error, :invalid_selector} =
             Queue.request(
               name,
               {:claim, 1, "worker", 100_000, %{"mailbox" => String.duplicate("x", 5_000)}}
             )

    assert %{pending: 1, claimed: 0} = Queue.request(name, :count)
  end

  defp wire_size(view) do
    [view]
    |> Alto.Protocol.encode_term()
    |> JSON.encode!()
    |> byte_size()
  end
end
