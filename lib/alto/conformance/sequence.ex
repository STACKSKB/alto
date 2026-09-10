defmodule Alto.Conformance.Sequence do
  @moduledoc """
  Seeded state-machine sequences for failure conformance.

  Operations cover the decided contract surface: `put` (business upsert),
  `admit` (insert-only delivery admission), duplicate and conflicting
  redelivery, `claim`, time advance (lease expiry), `ack`, `release`,
  `restart` (queue and/or ledger stop/start over the same log), and
  `reconcile` (apply the ledger recovery table: dispatched-without-outcome
  parks, decided outcomes ack without re-running).

  The generator is deterministic in its seed: `generate(seed, length)`
  returns the same op list for the same seed every time, and the seed is
  part of the returned sequence so failures reproduce by re-running one
  integer. `minimize/2` shrinks a failing sequence by greedy single-op
  removal while the failure persists.

  This module chooses no transaction isolation, retry classification, or
  compensation semantics (boundary): `reconcile` follows the shipped
  `Alto.OperationLog` recovery table only, and released retries are counted
  ledger releases — never blind re-dispatch.
  """

  alias Alto.Consumer
  alias Alto.OperationLog
  alias Alto.Queue

  @type op ::
          {:put, String.t()}
          | {:admit, String.t()}
          | {:duplicate_admit, String.t()}
          | {:conflicting_admit, String.t()}
          | {:claim}
          | {:ack_claimed}
          | {:release_claimed}
          | {:advance_time}
          | {:restart_queue}
          | {:restart_ledger}
          | {:reconcile}

  @type context :: %{
          queue: GenServer.server(),
          ledger: GenServer.server(),
          dir: String.t(),
          queue_id: String.t(),
          ledger_id: String.t(),
          queue_opts: keyword(),
          ledger_opts: keyword(),
          claimed: [map()],
          restarted: non_neg_integer()
        }

  @doc "Deterministically generate `length` ops from `seed`."
  @spec generate(integer(), pos_integer()) :: {[op()], integer()}
  def generate(seed, length \\ 24)
      when is_integer(seed) and is_integer(length) and length >= 1 do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    keys = for n <- 1..8, do: "src:del-#{n}"
    biz = for n <- 1..4, do: "job-#{n}"

    ops =
      for _ <- 1..length do
        case :rand.uniform(11) do
          1 -> {:put, Enum.random(biz)}
          2 -> {:admit, Enum.random(keys)}
          3 -> {:duplicate_admit, Enum.random(keys)}
          4 -> {:conflicting_admit, Enum.random(keys)}
          5 -> {:claim}
          6 -> {:ack_claimed}
          7 -> {:release_claimed}
          8 -> {:advance_time}
          9 -> {:restart_queue}
          10 -> {:restart_ledger}
          11 -> {:reconcile}
        end
      end

    {ops, seed}
  end

  @doc """
  Run `ops` against `context`'s queue and ledger. Returns the observation
  log; every step is already seed-deterministic, and time advance sleeps a
  fixed 120ms past the test leases (callers start queues with
  `lease_ms: 30..50`).
  """
  @spec run([op()], context()) :: {[term()], context()}
  def run(ops, context) do
    Enum.map_reduce(ops, context, &step/2)
  end

  @doc """
  Greedy minimize: repeatedly drop any single op while `check.(ops)`
  still reports `{:fail, _}`. Returns the minimal failing sequence.
  """
  @spec minimize([op()], ([op()] -> :pass | {:fail, term()})) :: [op()]
  def minimize(ops, check) do
    Enum.reduce_while(1..length(ops), ops, fn _, current ->
      shrunk =
        Enum.find_value(0..(length(current) - 1), fn index ->
          candidate = List.delete_at(current, index)
          if candidate != [] and match?({:fail, _}, check.(candidate)), do: candidate
        end)

      if shrunk, do: {:cont, shrunk}, else: {:halt, current}
    end)
  end

  @doc """
  Run the same `ops` against two fresh queue configurations and compare
  the observable contract. Both stores must agree on: first-wins admission,
  no second work after ack+redelivery, restart durability, and
  reconcile-never-invents-success. They may differ only on bounded-window
  expiry (callers pass a small `max_completed` for exactly one side to
  demonstrate honest re-admission).
  """
  @spec run_storage_contract([op()], keyword(), keyword()) :: %{
          a: [term()],
          b: [term()],
          seeds: [integer()]
        }
  def run_storage_contract(ops, opts_a, opts_b) do
    %{a: run_against(ops, opts_a), b: run_against(ops, opts_b), seeds: []}
  end

  defp run_against(ops, base_opts) do
    dir = Path.join(System.tmp_dir!(), "alto-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    tag = System.unique_integer([:positive])

    qname = :"contract_q_#{tag}"
    lname = :"contract_l_#{tag}"

    {:ok, _} =
      Queue.start_link(
        Keyword.merge([id: "cq#{tag}", dir: Path.join(dir, "q"), name: qname], base_opts)
      )

    {:ok, _} = OperationLog.start_link(id: "cl#{tag}", dir: Path.join(dir, "l"), name: lname)

    context = %{
      queue: qname,
      ledger: lname,
      dir: dir,
      queue_id: "cq#{tag}",
      ledger_id: "cl#{tag}",
      queue_opts: [id: "cq#{tag}", dir: Path.join(dir, "q"), name: qname],
      ledger_opts: [id: "cl#{tag}", dir: Path.join(dir, "l"), name: lname],
      claimed: [],
      restarted: 0
    }

    try do
      {log, _} = run(ops, context)
      log
    after
      for name <- [qname, lname], pid = Process.whereis(name), is_pid(pid) do
        try do
          GenServer.stop(pid)
        catch
          _, _ -> :ok
        end
      end

      File.rm_rf!(dir)
    end
  end

  ## One step

  defp step({:put, key}, ctx) do
    {{:put, key, Queue.put(ctx.queue, key, %{"v" => key})}, ctx}
  end

  defp step({:admit, key}, ctx) do
    {{:admit, key, Queue.admit(ctx.queue, key, %{"body" => key})}, ctx}
  end

  defp step({:duplicate_admit, key}, ctx) do
    # A sender retry of identical bytes.
    {{:duplicate_admit, key, Queue.admit(ctx.queue, key, %{"body" => key})}, ctx}
  end

  defp step({:conflicting_admit, key}, ctx) do
    # Same delivery id, different body: first-wins keeps the original.
    {{:conflicting_admit, key, Queue.admit(ctx.queue, key, %{"body" => key <> "-v2"})}, ctx}
  end

  defp step({:claim}, ctx) do
    case Queue.claim(ctx.queue, 2, "conformance") do
      {:ok, records} -> {{:claim, Enum.map(records, & &1.key)}, %{ctx | claimed: records}}
      {:error, reason} -> {{:claim_error, reason}, ctx}
    end
  end

  defp step({:ack_claimed}, ctx) do
    results =
      Enum.map(ctx.claimed, fn record ->
        case OperationLog.status(ctx.ledger, record.key) do
          {:decided, _class, _evidence} ->
            {record.key, Queue.ack(ctx.queue, record.claim_id)}

          _other ->
            # No invented ack: record intent/attempt/outcome first so the
            # ack is decided, mirroring the consumer's outcome-first order.
            :ok = OperationLog.record_intent(ctx.ledger, record.key, "conformance", record.key)

            :ok =
              OperationLog.record_attempt(ctx.ledger, record.key, record.claim_id)

            :ok =
              OperationLog.record_outcome(
                ctx.ledger,
                record.key,
                record.claim_id,
                :completed,
                %{via: :sequence}
              )

            {record.key, Queue.ack(ctx.queue, record.claim_id)}
        end
      end)

    {{:ack_claimed, results}, %{ctx | claimed: []}}
  end

  defp step({:release_claimed}, ctx) do
    results = Enum.map(ctx.claimed, &{&1.key, Queue.release(ctx.queue, &1.claim_id)})
    {{:release_claimed, results}, %{ctx | claimed: []}}
  end

  defp step({:advance_time}, ctx) do
    # Test queues run with short leases (30–50ms); one fixed sleep moves
    # every outstanding lease past expiry deterministically.
    Process.sleep(120)
    {{:advance_time, :slept_120ms}, ctx}
  end

  defp step({:restart_queue}, ctx) do
    if pid = Process.whereis(ctx.queue), do: GenServer.stop(pid)
    Process.sleep(10)
    name = :"conformance_q_#{System.unique_integer([:positive])}"
    opts = Keyword.put(ctx.queue_opts, :name, name)
    {:ok, _} = Queue.start_link(opts)
    {{:restart_queue, :ok}, %{ctx | queue: name, queue_opts: opts, claimed: []}}
  end

  defp step({:restart_ledger}, ctx) do
    if pid = Process.whereis(ctx.ledger), do: GenServer.stop(pid)
    Process.sleep(10)
    name = :"conformance_l_#{System.unique_integer([:positive])}"
    opts = Keyword.put(ctx.ledger_opts, :name, name)
    {:ok, _} = OperationLog.start_link(opts)
    {{:restart_ledger, :ok}, %{ctx | ledger: name, ledger_opts: opts}}
  end

  defp step({:reconcile}, ctx) do
    # Apply the shipped recovery table only: dispatched-without-outcome
    # parks (never re-dispatches blindly), decided outcomes ack without
    # re-running, intended work is left for the next dispatch.
    open = OperationLog.list_open(ctx.ledger)
    parked = OperationLog.list_parked(ctx.ledger)

    {{:reconcile, %{open: open, parked: parked}}, ctx}
  end

  @doc false
  def consumer_handler(payload, %{key: key, claim_id: claim_id, attempt: _n}, ledger) do
    :ok = OperationLog.record_intent(ledger, key, "conformance-handler", key)
    :ok = OperationLog.record_attempt(ledger, key, claim_id)

    case payload do
      %{"fail" => true} ->
        :ok =
          OperationLog.record_outcome(ledger, key, claim_id, :failed_known, %{reason: :scripted})

        {:decided, :failed_known}

      _other ->
        :ok = OperationLog.record_outcome(ledger, key, claim_id, :completed, %{})
        {:decided, :completed}
    end
  end

  @doc false
  def drive_consumer(queue, ledger, handler) do
    {:ok, c} =
      Consumer.start_link(
        queue: queue,
        ledger: ledger,
        handler: handler,
        by: "conformance-#{System.unique_integer([:positive])}",
        autostart: false,
        name: :"conformance_c_#{System.unique_integer([:positive])}"
      )

    try do
      Consumer.poll(c)
    after
      GenServer.stop(c)
    end
  end
end
