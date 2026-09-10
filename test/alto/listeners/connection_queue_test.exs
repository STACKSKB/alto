defmodule Alto.Listeners.ConnectionQueueTest do
  @moduledoc """
  The claim/ack surface over the wire: `queue_claim` / `queue_ack` /
  `queue_release` ride the same envelope codec and connection dispatch as
  every other command, answering `unsupported` when no queue is configured.
  """

  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Listeners.Connection

  setup do
    dir = Path.join(System.tmp_dir!(), "alto-conn-queue-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    queue = :"conn-queue-#{System.unique_integer([:positive])}"
    {:ok, _} = Alto.Queue.start_link(id: "conn-queue", dir: dir, name: queue)

    registry = :"conn-registry-#{System.unique_integer([:positive])}"
    bare_registry = :"conn-registry-bare-#{System.unique_integer([:positive])}"

    resolver = fn _name -> {:error, {:unknown_config, "nope"}} end

    start_supervised!(%{
      id: registry,
      start: {Registry, :start_link, [[name: registry, config_resolver: resolver, queue: queue]]}
    })

    start_supervised!(%{
      id: bare_registry,
      start: {Registry, :start_link, [[name: bare_registry, config_resolver: resolver]]}
    })

    %{registry: registry, bare_registry: bare_registry, queue: queue}
  end

  defp run(line, registry) do
    Connection.run_command(line, registry, fn out -> send(self(), {:line, out}) end)

    assert_receive {:line, out}
    JSON.decode!(IO.iodata_to_binary(out))
  end

  defp run_with_limit(line, registry, max_line_bytes) do
    Connection.run_command(
      line,
      registry,
      fn out -> send(self(), {:line, out}) end,
      max_line_bytes
    )

    assert_receive {:line, out}
    JSON.decode!(IO.iodata_to_binary(out))
  end

  test "claim, ack, and release round-trip through the protocol", %{
    registry: registry,
    queue: queue
  } do
    assert {:ok, %{id: id}} = Alto.Queue.put(queue, "job-1", %{lines: 3})

    claim =
      run(
        JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-1", "by" => "station"}),
        registry
      )

    assert claim["type"] == "ok"

    assert [
             %{
               "id" => ^id,
               "key" => "job-1",
               "payload" => %{"lines" => 3},
               "claim_id" => claim_id,
               "claimed_by" => "station"
             }
           ] = claim["records"]

    ack =
      run(
        JSON.encode!(%{"v" => 1, "type" => "queue_ack", "id" => "c-2", "claim_id" => claim_id}),
        registry
      )

    assert ack["type"] == "ok"
    assert %{pending: 0, claimed: 0} = Alto.Queue.count(queue)
  end

  test "unknown claim ids answer not_found, and no queue answers unsupported", %{
    registry: registry,
    bare_registry: bare_registry
  } do
    ack =
      run(
        JSON.encode!(%{"v" => 1, "type" => "queue_ack", "id" => "c-3", "claim_id" => "clm-ghost"}),
        registry
      )

    assert ack == %{
             "v" => 1,
             "type" => "error",
             "id" => "c-3",
             "code" => "not_found",
             "detail" => "not_found"
           }

    claim = run(JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-4"}), bare_registry)

    assert claim["code"] == "unsupported"
    assert claim["detail"] == "no_queue"
  end

  test "an unknown run configuration answers not_found", %{registry: registry} do
    reply =
      run(
        JSON.encode!(%{
          "v" => 1,
          "type" => "start_run",
          "id" => "start-unknown",
          "config" => "missing",
          "task" => "task"
        }),
        registry
      )

    assert reply["type"] == "error"
    assert reply["code"] == "not_found"
  end

  describe "bounded claims" do
    test "twenty 60KB records produce a bounded response with no orphaned claims", %{
      registry: registry,
      queue: queue
    } do
      for n <- 1..20 do
        {:ok, _} = Alto.Queue.put(queue, "job-#{n}", %{pad: String.duplicate("x", 60_000)})
      end

      claim =
        run(
          JSON.encode!(%{
            "v" => 1,
            "type" => "queue_claim",
            "id" => "c-big",
            "count" => 20,
            "by" => "station"
          }),
          registry
        )

      assert claim["type"] == "ok"
      returned = claim["records"]
      assert length(returned) < 20
      assert length(returned) > 0

      # Every leased record was delivered: no invisible leases.
      assert %{pending: pending, claimed: claimed} = Alto.Queue.count(queue)
      assert pending + claimed == 20
      assert claimed == length(returned)

      # The rest is still claimable work.
      assert {:ok, rest} = Alto.Queue.claim(queue, 20, "station-2")
      assert length(rest) == pending
    end

    test "listener-specific limits bound the reply", %{registry: registry, queue: queue} do
      {:ok, _} = Alto.Queue.put(queue, "a", %{n: 1})
      {:ok, _} = Alto.Queue.put(queue, "b", %{n: 2})

      claim =
        run_with_limit(
          JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-small", "count" => 10}),
          registry,
          4_096
        )

      assert claim["type"] == "ok"
      assert length(claim["records"]) <= 2
      assert IO.iodata_length(JSON.encode!(claim)) <= 4_096
    end

    test "one oversized record is an explicit failure with nothing leased", %{
      registry: registry,
      queue: queue
    } do
      {:ok, _} = Alto.Queue.put(queue, "big", %{pad: String.duplicate("x", 60_000)})

      claim =
        run_with_limit(
          JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-huge", "count" => 5}),
          registry,
          1_024
        )

      assert claim["type"] == "error"
      assert claim["code"] == "internal"
      assert ["record_too_large", %{"key" => "big"}] = claim["detail"]["$tuple"]
      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)
    end

    test "a dead queue answers errors while the registry stays alive", %{
      registry: registry,
      queue: queue,
      bare_registry: bare_registry
    } do
      pid = Process.whereis(queue)
      GenServer.stop(pid)

      claim =
        run(
          JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-dead"}),
          registry
        )

      assert claim["type"] == "error"
      assert claim["code"] == "internal"

      ack =
        run(
          JSON.encode!(%{
            "v" => 1,
            "type" => "queue_ack",
            "id" => "c-dead-ack",
            "claim_id" => "clm-ghost"
          }),
          registry
        )

      assert ack["type"] == "error"

      # Unrelated registry work is unaffected.
      unknown =
        run(
          JSON.encode!(%{
            "v" => 1,
            "type" => "start_run",
            "id" => "c-alive",
            "config" => "missing",
            "task" => "task"
          }),
          registry
        )

      assert unknown["code"] == "not_found"

      # And a queue-less registry still answers unsupported.
      claim2 =
        run(JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-bare"}), bare_registry)

      assert claim2["code"] == "unsupported"
    end

    test "disconnect expiry reclaims; stale handles stay dead", %{queue: queue} do
      {:ok, _} = Alto.Queue.put(queue, "job-1", %{n: 1})

      # Drive expiry explicitly so persistence latency cannot expire the new lease.
      dir =
        Path.join(System.tmp_dir!(), "alto-claim-expiry-#{System.unique_integer([:positive])}")

      name = :"expiry-queue-#{System.unique_integer([:positive])}"
      clock = :atomics.new(1, [])
      :atomics.put(clock, 1, 1_000)

      {:ok, _} =
        Alto.Queue.start_link(
          id: "expiry",
          dir: dir,
          name: name,
          lease_ms: 20,
          clock: fn -> :atomics.get(clock, 1) end
        )

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, _} = Alto.Queue.put(name, "job", %{})
      {:ok, [first]} = Alto.Queue.claim(name, 1, "gone-station")
      # The client disconnects without acking; the lease expires.
      :atomics.add(clock, 1, 60)
      {:ok, [second]} = Alto.Queue.claim(name, 1, "next-station")

      assert second.id == first.id
      assert second.claim_id != first.claim_id
      assert {:error, :not_found} = Alto.Queue.ack(name, first.claim_id)
      assert :ok = Alto.Queue.ack(name, second.claim_id)
    end
  end
end
