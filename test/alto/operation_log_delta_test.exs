defmodule Alto.OperationLogDeltaTest do
  use ExUnit.Case, async: true
  alias Alto.{OperationLog, Persistence.Codec, Persistence.Delta, Subagents.Continuation}

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-ledger-delta-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "sibling checkpoint bodies appear once under default ledger limits and survive restart", %{
    dir: dir
  } do
    {:ok, ledger} = OperationLog.start_link(id: "siblings", dir: dir)
    ids = Enum.map(1..8, &"child-#{&1}")
    {:ok, batch} = Continuation.open(ledger, "batch", ids)

    for id <- ids do
      {:ok, ticket} = Continuation.dispatch(batch, id)
      {:ok, _} = Continuation.suspend(ticket, %{"state" => id <> String.duplicate("x", 32_768)})
    end

    {:ok, before} = Continuation.read(batch)
    path = Path.join(dir, "siblings.jsonl")

    commands =
      File.stream!(path)
      |> Enum.map(fn line ->
        {:ok, command} = Codec.decode(JSON.decode!(line))
        command
      end)

    assert Enum.any?(commands, &(elem(&1, 0) == :checkpoint_delta))

    for id <- ids do
      body = id <> String.duplicate("x", 32_768)
      assert Enum.reduce(commands, 0, &(occurrences(&1, body) + &2)) == 1
    end

    assert File.stat!(path).size < 500_000
    identity = Continuation.identity(batch)
    GenServer.stop(ledger)
    {:ok, restarted} = OperationLog.start_link(id: "siblings", dir: dir)
    {:ok, reopened} = Continuation.restore(restarted, identity)
    assert {:ok, ^before} = Continuation.read(reopened)
    GenServer.stop(restarted)
  end

  test "tuple decision and grant transitions preserve large saved bodies", %{dir: dir} do
    {:ok, ledger} = OperationLog.start_link(id: "tuples", dir: dir)
    body = String.duplicate("checkpoint", 3000)
    recovery = %{"generation" => "generation"}
    first = %{"child" => {:suspended, "attempt", "token", %{"state" => body}}}
    :ok = OperationLog.request(ledger, {:retain, "cell", "kind", recovery, "attempt", first})
    second = %{"child" => {:decided, "attempt", "token", %{"state" => body}, :approve}}

    assert {:ok, _} =
             OperationLog.request(ledger, {:checkpoint_update, "cell", {1, "generation"}, second})

    third = %{"child" => {:granted, "attempt", "token", %{"state" => body}, :approve, "grant"}}

    assert {:ok, _} =
             OperationLog.request(ledger, {:checkpoint_update, "cell", {2, "generation"}, third})

    path = Path.join(dir, "tuples.jsonl")
    lines = File.stream!(path) |> Enum.to_list()
    assert byte_size(Enum.at(lines, 1)) < 1000
    assert byte_size(Enum.at(lines, 2)) < 1000
    GenServer.stop(ledger)
    File.write!(path, "\"torn-delta", [:append])
    {:ok, restarted} = OperationLog.start_link(id: "tuples", dir: dir)

    assert {:ok, %{checkpoint: ^third, revision: 3}} =
             OperationLog.request(restarted, {:recovery, "cell"})

    assert {:error, :stale_revision} =
             OperationLog.request(
               restarted,
               {:checkpoint_update, "cell", {2, "generation"}, second}
             )

    GenServer.stop(restarted)
  end

  test "wrong base and impossible tuple resize are rejected during replay", %{dir: dir} do
    for {id, hash, operations} <- [
          {"bad-base", <<0::256>>, [{:put, ["n"], 2}]},
          {"bad-resize", Delta.hash(%{"n" => 1}), [{:resize, ["n"], 1_000_000_000}]}
        ] do
      {:ok, ledger} = OperationLog.start_link(id: id, dir: dir)
      :ok = OperationLog.request(ledger, {:retain, "cell", "kind", nil, "attempt", %{"n" => 1}})
      GenServer.stop(ledger)
      {:ok, encoded} = Codec.encode({:checkpoint_delta, "cell", 1, hash, operations})
      File.write!(Path.join(dir, id <> ".jsonl"), JSON.encode!(encoded) <> "\n", [:append])
      assert {:error, {:ledger_corrupt, ^id, 2}} = OperationLog.start_link(id: id, dir: dir)
    end
  end

  test "delta bounds never acknowledge an unreplayable large tuple", %{dir: dir} do
    {:ok, ledger} =
      OperationLog.start_link(id: "large-tuple", dir: dir, max_record_bytes: 500_000)

    old = %{"tuple" => {:old}}
    value = %{"tuple" => List.duplicate(nil, 10_001) |> List.to_tuple()}
    :ok = OperationLog.request(ledger, {:retain, "cell", "kind", nil, "attempt", old})
    assert {:ok, _} = OperationLog.request(ledger, {:checkpoint_update, "cell", 1, value})
    GenServer.stop(ledger)

    {:ok, restarted} =
      OperationLog.start_link(id: "large-tuple", dir: dir, max_record_bytes: 500_000)

    assert {:ok, %{checkpoint: ^value}} = OperationLog.request(restarted, {:recovery, "cell"})
    GenServer.stop(restarted)
  end

  defp occurrences(term, body) when is_binary(term), do: if(term == body, do: 1, else: 0)
  defp occurrences(term, body) when is_tuple(term), do: occurrences(Tuple.to_list(term), body)
  defp occurrences(term, body) when is_map(term), do: occurrences(Map.to_list(term), body)

  defp occurrences(term, body) when is_list(term),
    do: Enum.reduce(term, 0, &(occurrences(&1, body) + &2))

  defp occurrences(_, _), do: 0
end
