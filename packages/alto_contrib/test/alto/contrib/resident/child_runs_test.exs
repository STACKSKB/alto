defmodule Alto.Contrib.Resident.ChildRunsTest do
  use ExUnit.Case, async: true

  alias Alto.Subagents.Continuation
  alias Alto.Contrib.Resident.{CLI, ChildRuns, Config}

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-child-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = make_ref()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: name}
  end

  defp config(dir, child_runs \\ []) do
    Config.new(
      workspace: dir,
      state_dir: Path.join(dir, "state"),
      profiles: %{"local" => Alto.Config.default()},
      child_runs: child_runs
    )
  end

  defp start_ledger(config, name) do
    start_supervised!(ChildRuns.child(config, name), id: {:child_runs, name})
    ChildRuns.ledger(name)
  end

  defp open!(ledger, key, ids) do
    {:ok, batch} = Continuation.open(ledger, key, ids, %{"parent_run_id" => "root"})
    batch
  end

  test "partial batch survives journal restart and reads do not mutate it", %{
    dir: dir,
    name: name
  } do
    ledger = start_ledger(config(dir), name)
    batch = open!(ledger, "partial", ["completed", "uncertain", "planned"])
    {:ok, ticket} = Continuation.dispatch(batch, "completed")
    {:ok, _} = Continuation.complete(ticket, %{"blob" => String.duplicate("x", 30_000)})
    {:ok, _} = Continuation.dispatch(batch, "uncertain")
    {:ok, before} = Continuation.read(batch)

    stop_supervised!({:child_runs, name})
    ledger = start_ledger(config(dir), name)
    commands = ChildRuns.commands(name)

    assert {:ok, after_restart} = Continuation.restore(ledger, Continuation.identity(batch))
    assert {:ok, %{revision: revision, packet: packet}} = Continuation.read(after_restart)
    assert revision == before.revision

    assert Enum.map(
             ["completed", "uncertain", "planned"],
             &to_string(elem(packet["children"][&1], 0))
           ) == ["completed", "dispatched", "planned"]

    assert {:ok, %{state: "active", counts: counts}} =
             commands["children.get"].(%{"key" => "partial"})

    assert counts == %{"completed" => 1, "dispatched" => 1, "planned" => 1}

    assert {:error, {:child_result_pending, "dispatched"}} =
             commands["children.result"].(%{
               "key" => "partial",
               "child" => "uncertain",
               "generation" => batch.generation,
               "revision" => revision
             })

    assert {:error, {:child_result_pending, "planned"}} =
             commands["children.result"].(%{
               "key" => "partial",
               "child" => "planned",
               "generation" => batch.generation,
               "revision" => revision
             })

    assert {:error, :child_already_admitted} = Continuation.dispatch(after_restart, "uncertain")
    assert {:ok, unchanged} = Continuation.read(after_restart)
    assert unchanged == before
  end

  test "result export is fenced and paginates exact retained bytes", %{dir: dir, name: name} do
    ledger = start_ledger(config(dir), name)
    batch = open!(ledger, "large", ["worker", "later"])
    {:ok, ticket} = Continuation.dispatch(batch, "worker")
    {:ok, _} = Continuation.complete(ticket, %{"blob" => String.duplicate("result", 8_000)})
    {:ok, snapshot} = Continuation.read(batch)
    commands = ChildRuns.commands(name)

    args = %{
      "key" => "large",
      "child" => "worker",
      "generation" => batch.generation,
      "revision" => snapshot.revision
    }

    assert {:ok, first} = commands["children.result"].(args)
    assert byte_size(first.chunk) == 24_000
    assert is_integer(first.next_cursor)

    pages =
      collect_result_pages(commands["children.result"], args, first.next_cursor, [first.chunk])

    encoded = Enum.join(pages)
    {:completed, _, retained} = snapshot.packet["children"]["worker"]
    assert {:ok, ^encoded} = Alto.Persistence.Codec.encode(retained)

    assert Alto.Persistence.Codec.decode(encoded) ==
             {:ok, %{"blob" => String.duplicate("result", 8_000)}}

    assert byte_size(encoded) == first.bytes
    assert :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower) == first.sha256

    assert {:error, :stale_child_batch} =
             commands["children.result"].(%{args | "revision" => snapshot.revision - 1})

    assert {:error, :stale_child_batch} =
             commands["children.result"].(%{args | "generation" => String.duplicate("0", 32)})

    assert {:ok, unchanged} = Continuation.read(batch)
    assert unchanged == snapshot

    {:ok, ticket} = Continuation.dispatch(batch, "later")
    {:ok, _} = Continuation.complete(ticket, %{"outcome" => "done"})

    assert {:error, :stale_child_batch} =
             commands["children.result"].(Map.put(args, "cursor", first.next_cursor))
  end

  test "list pagination exposes more than ten batches", %{dir: dir, name: name} do
    ledger = start_ledger(config(dir), name)

    for index <- 1..11 do
      batch = open!(ledger, "batch-#{index}", ["worker"])
      {:ok, ticket} = Continuation.dispatch(batch, "worker")
      {:ok, _} = Continuation.complete(ticket, %{"index" => index})
    end

    commands = ChildRuns.commands(name)
    assert {:ok, %{batches: first, next_cursor: 10}} = commands["children.list"].(%{})
    assert length(first) == 10

    assert {:ok, %{batches: second, next_cursor: nil}} =
             commands["children.list"].(%{"cursor" => 10})

    assert length(second) == 1
  end

  test "approval inspection preserves the viewed child identity across sibling decisions", %{
    dir: dir,
    name: name
  } do
    ledger = start_ledger(config(dir), name)
    batch = open!(ledger, "approvals", ["one", "two"])
    request = %{"tool" => "write", "input" => "original"}

    for id <- ["one", "two"] do
      {:ok, ticket} = Continuation.dispatch(batch, id)
      {:ok, _} = Continuation.suspend(ticket, %{"request" => request})
    end

    {:ok, before} = Continuation.read(batch)
    command = ChildRuns.commands(name)["children.approval"]

    args = %{
      "key" => batch.key,
      "child" => "one",
      "generation" => batch.generation,
      "revision" => before.revision
    }

    assert {:ok, first} = command.(args)
    assert first.request == request
    assert first.revision == before.revision
    assert first.state == :suspended
    assert {:ok, ^before} = Continuation.read(batch)
    assert {:error, _} = command.(%{args | "generation" => "replaced"})

    {:ok, sibling} = command.(%{args | "child" => "two"})
    {:ok, _} = Continuation.decide(batch, before.revision, sibling.identity, :deny)
    assert {:error, :stale_child_approval} = command.(args)

    {:ok, after_decision} = Continuation.read(batch)
    assert {:ok, current} = command.(%{args | "revision" => after_decision.revision})
    assert current.identity == first.identity
    assert current.request == request
    assert current.state == :suspended
    assert {:ok, ^after_decision} = Continuation.read(batch)
  end

  test "retention full protects an active batch", %{dir: dir, name: name} do
    ledger = start_ledger(config(dir, max_retained: 1), name)
    batch = open!(ledger, "held", ["worker"])
    {:ok, ticket} = Continuation.dispatch(batch, "worker")
    {:ok, _} = Continuation.complete(ticket, %{"outcome" => "retained but not consumed"})
    assert {:error, :ledger_full} = Continuation.open(ledger, "overflow", ["worker"], %{})
    assert {:ok, %{results: [{"worker", _}]}} = Continuation.join(batch)
  end

  test "invalid child journal bounds are rejected", %{dir: dir} do
    for options <- [
          [max_retained: 0],
          [max_log_bytes: 99_999],
          [max_batch_bytes: 63_999],
          [unknown: 1]
        ] do
      assert_raise ArgumentError, fn -> config(dir, options) end
    end
  end

  test "CLI requires generation and revision for result export" do
    assert {:error, :team_result_requires_generation_and_revision} ==
             CLI.run(["team-result", "key", "child"])

    assert {:error, :team_result_requires_generation_and_revision} ==
             CLI.run(["team-result", "key", "child", "--generation", "", "--revision", "1"])

    assert {:error, {:invalid_team_result, :cursor}} ==
             CLI.run([
               "team-result",
               "key",
               "child",
               "--generation",
               "generation",
               "--revision",
               "1",
               "--cursor",
               "-1"
             ])
  end

  defp collect_result_pages(_command, _args, nil, chunks), do: chunks

  defp collect_result_pages(command, args, cursor, chunks) do
    {:ok, page} = command.(Map.put(args, "cursor", cursor))
    collect_result_pages(command, args, page.next_cursor, chunks ++ [page.chunk])
  end
end
