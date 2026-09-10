defmodule Alto.Consumer do
  @moduledoc """
  A bounded durable inbox consumer: claim → short run → outcome
  handling → ack or park.

  Each poll claims at most `batch` records within `claim_bytes`, then
  handles them one at a time under the ledger's recovery table
  (`Alto.OperationLog`):

    * decided outcome on record → ack *without* re-running;
    * dispatched without outcome → park (`:requires_operator`, acked) —
      the previous attempt may have committed;
    * intended / fresh → record intent + attempt, run the handler;
    * attempts exhausted → park (`:attempts_exhausted`, acked);
    * handler `:done` → `:completed`, ack;
    * handler `{:failed, reason}` → `:failed_known`, ack (terminal);
    * handler `{:retry, reason}` → queue release + ledger release line
      (a counted retry, the only path back to intended);
    * handler `{:park, reason}` or handler silence (crash/timeout past
      `handle_timeout`) → `:requires_operator`, ack.

  Ack happens only after the outcome is durably recorded; any store
  failure before that leaves the work live (lease expiry hands it to
  another worker, which parks it). Ack failures (`:lease_expired`,
  `:not_found`) are logged and skipped — a newer owner, if any, reconciles
  through the same table.

  Fencing, leases, bounds, restarts:

    * **ownership fencing** is the queue `claim_id`: it rotates on every
      claim, so a stale worker's ack answers `:not_found` and can never
      acknowledge a newer owner's claim;
    * **safe expiry, no renewal**: work must fit the queue lease; expired
      work is re-claimed and governed by ledger state, never replayed
      blindly;
    * **attempt bounds** (`max_attempts`, default 3) cap retries; unknown
      outcomes park on first sight, before any repeat;
    * **restart**: a dead worker's lease expires; the next claim finds
      `dispatched` and parks, or `decided` and acks;
    * **placement**: workers are plain supervised processes that *call*
      the queue/ledger/registry. The registry never waits on a worker, so
      a stuck downstream blocks only its worker's poll loop, and handler
      execution is bounded by `handle_timeout`.

  The handler contract:

      handler.(payload, %{key: key, claim_id: id, attempt: n}) ::
        :done | {:done, evidence} | {:failed, reason} |
        {:retry, reason} | {:park, reason} | {:run, runner_result} |
        {:outcome, outcome_class, evidence}

  `evidence` must be a map (scrubbed of credentials by the ledger).
  `Alto.Consumer.worst_outcome/1` folds a short run's tool events into
  `:unknown | :failed | :completed | :empty` for handlers built on
  `Alto.run/2`.
  """

  use GenServer

  require Logger

  @default_max_attempts 3
  @default_poll_ms 250
  @default_claim_bytes 262_144
  @default_handle_timeout 60_000
  @default_batch 1
  @default_tool "consumer_handler"

  ## Client API

  @doc """
  Start a consumer. Options:

    * `:queue` — `Alto.Queue` server (required);
    * `:ledger` — `Alto.OperationLog` server (required);
    * `:handler` — `fun/2` (required, see module docs);
    * `:by` — claim owner tag (default `"consumer"`, unique per worker);
    * `:tool` — tool name recorded in ledger intents;
    * `:max_attempts` — counted retries before parking (default 3);
    * `:poll_ms` — idle delay between polls (default 250);
    * `:claim_bytes` — encoded-bytes claim budget (default 256 KiB);
    * `:batch` — max records per poll (default 1);
    * `:handle_timeout` — handler deadline in ms (default 60,000);
    * `:autostart` — begin polling on start (default true; tests pass false
      and drive `poll/1`);
    * `:name` — registered name.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run one claim-handle cycle synchronously: `:idle` or `{:handled, [action]}`."
  @spec poll(GenServer.server()) :: :idle | {:handled, [atom()]} | {:error, term()}
  def poll(server \\ __MODULE__) do
    GenServer.call(server, :poll, :infinity)
  end

  @doc "Read an authoritative runner verdict or fold legacy tool events."
  @spec worst_outcome([Alto.Event.t()] | Alto.Runner.Serial.Result.t()) ::
          :unknown | :failed | :completed | :empty
  def worst_outcome(%Alto.Runner.Serial.Result{verdict: :unknown}), do: :unknown

  def worst_outcome(%Alto.Runner.Serial.Result{verdict: class})
      when class in [:failed_known, :rejected_before_dispatch],
      do: :failed

  def worst_outcome(%Alto.Runner.Serial.Result{verdict: :completed}), do: :completed
  def worst_outcome(%Alto.Runner.Serial.Result{verdict: :empty}), do: :empty

  def worst_outcome(events) do
    classes =
      for event <- events,
          event.type in [:tool_completed, :tool_failed],
          do: event.data[:outcome]

    cond do
      :unknown in classes ->
        :unknown

      Enum.any?(classes, &(&1 in [:failed_known, :rejected_before_dispatch])) ->
        :failed

      Enum.any?(events, fn
        %{type: :run_cancelled, data: %{in_flight: %{outcome: :unknown}}} -> true
        %{type: :run_cancelled, data: %{in_flight: %{outcome: %{class: :unknown}}}} -> true
        _event -> false
      end) ->
        :unknown

      :completed in classes ->
        :completed

      true ->
        :empty
    end
  end

  ## Server implementation

  @impl true
  def init(opts) do
    with {:ok, queue} <- Keyword.fetch(opts, :queue),
         {:ok, ledger} <- Keyword.fetch(opts, :ledger),
         {:ok, handler} <- Keyword.fetch(opts, :handler),
         true <- is_function(handler, 2) do
      state = %{
        queue: queue,
        ledger: ledger,
        handler: handler,
        by: Keyword.get(opts, :by, "consumer"),
        tool: Keyword.get(opts, :tool, @default_tool),
        max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
        poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
        claim_bytes: Keyword.get(opts, :claim_bytes, @default_claim_bytes),
        handle_timeout: Keyword.get(opts, :handle_timeout, @default_handle_timeout),
        batch: Keyword.get(opts, :batch, @default_batch)
      }

      if Keyword.get(opts, :autostart, true), do: schedule_tick(state.poll_ms)
      {:ok, state}
    else
      :error -> {:stop, :missing_consumer_option}
      false -> {:stop, :invalid_handler}
    end
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {reply, state} = cycle(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_reply, state} = cycle(state)
    schedule_tick(state.poll_ms)
    {:noreply, state}
  end

  defp schedule_tick(poll_ms), do: Process.send_after(self(), :tick, poll_ms)

  ## One cycle

  defp cycle(state) do
    case guarded_claim(state) do
      {:error, reason} ->
        Logger.warning("alto consumer: claim failed: #{inspect(reason, limit: 3)}")
        {{:error, reason}, state}

      {:ok, []} ->
        {:idle, state}

      {:ok, records} ->
        actions = Enum.map(records, &handle_record(&1, state))
        {{:handled, actions}, state}
    end
  end

  defp guarded_claim(state) do
    Alto.Queue.claim_bounded(state.queue, state.batch, state.by, state.claim_bytes)
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  defp handle_record(record, state) do
    op = operation_key(record)
    claim_id = record.claim_id

    case ledger_status(state, op) do
      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}

      :no_intent ->
        case ledger_call(state, fn ->
               Alto.OperationLog.record_intent(
                 ledger(state),
                 op,
                 state.tool,
                 record.key,
                 %{key: record.key, generation_id: record.generation_id, payload: record.payload}
               )
             end) do
          :ok ->
            dispatch(op, claim_id, record.payload, state)

          {:error, reason} ->
            release_quietly(state, claim_id)
            {:error, reason}
        end

      {:intended} ->
        dispatch(op, claim_id, record.payload, state)

      {:checkpointed, _checkpoint, _attempt} ->
        ack_quietly(state, claim_id)
        :acked_checkpoint

      {:dispatched, attempt} ->
        park_existing(
          op,
          claim_id,
          attempt,
          :previous_attempt_unknown,
          %{prior: :dispatched},
          state
        )

      {:decided, class, _evidence}
      when record.admission == :recovery and class in [:unknown, :requires_operator] ->
        release_quietly(state, claim_id)
        :awaiting_reconciliation

      {:decided, :unknown, _evidence} ->
        ack_quietly(state, claim_id)
        :parked_unknown

      {:decided, _class, _evidence} ->
        ack_quietly(state, claim_id)
        :acked_decided
    end
  end

  # Fresh intent or a released retry: count attempts, then run.
  defp dispatch(op, claim_id, payload, state) do
    case attempt_count(state, op) do
      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}

      {:ok, attempt_n} when attempt_n >= state.max_attempts ->
        park(op, claim_id, :attempts_exhausted, %{}, state)

      {:ok, attempt_n} ->
        case ledger_call(state, fn ->
               Alto.OperationLog.record_attempt(ledger(state), op, claim_id)
             end) do
          :ok ->
            run_handler(op, claim_id, attempt_n + 1, payload, state)

          {:error, reason} ->
            release_quietly(state, claim_id)
            {:error, reason}
        end
    end
  end

  defp attempt_count(state, op) do
    total = Alto.OperationLog.attempts(ledger(state), op)

    checkpointed =
      case Alto.OperationLog.recovery(ledger(state), op) do
        {:ok, %{checkpointed_attempts: attempts}} -> length(attempts)
        _ -> 0
      end

    {:ok, max(total - checkpointed, 0)}
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  # The handler is linked to its owning consumer. A consumer crash therefore
  # cannot leave the handler alive with authority to commit after ownership
  # has moved. Timeout deliberately unlinks before killing the child so the
  # consumer can record the bounded uncertainty outcome.
  defp run_handler(op, claim_id, attempt_n, payload, state) do
    caller = self()
    ref = make_ref()
    handler = state.handler

    pid =
      spawn_link(fn ->
        outcome =
          try do
            {:verdict,
             handler.(payload, %{
               key: op,
               operation_key: op,
               claim_id: claim_id,
               attempt: attempt_n
             })}
          rescue
            error -> {:raised, Exception.message(error)}
          catch
            kind, reason -> {:caught, kind, inspect(reason, limit: 3)}
          end

        send(caller, {ref, outcome})
      end)

    receive do
      {^ref, {:verdict, verdict}} ->
        apply_verdict(op, claim_id, verdict, state)

      {^ref, {:raised, message}} ->
        park(op, claim_id, :handler_crashed, %{error: message}, state)

      {^ref, {:caught, kind, reason}} ->
        park(op, claim_id, :handler_crashed, %{caught: kind, reason: reason}, state)
    after
      state.handle_timeout ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        park(op, claim_id, :handler_timeout, %{timeout_ms: state.handle_timeout}, state)
    end
  end

  defp apply_verdict(op, claim_id, verdict, state) do
    case verdict do
      :done ->
        decide(op, claim_id, :completed, %{}, state)

      {:done, evidence} when is_map(evidence) ->
        decide(op, claim_id, :completed, evidence, state)

      {:failed, reason} ->
        decide(op, claim_id, :failed_known, %{reason: inspect(reason, limit: 5)}, state)

      {:run, %Alto.Runner.Serial.Result{} = result} ->
        apply_run_verdict(op, claim_id, result, state)

      {:outcome, class, evidence}
      when class in [:completed, :rejected_before_dispatch, :failed_known, :unknown] and
             is_map(evidence) ->
        decide(op, claim_id, class, evidence, state)

      {:retry, _reason} ->
        retry(op, claim_id, state)

      {:checkpoint, checkpoint} when is_map(checkpoint) ->
        checkpoint(op, claim_id, checkpoint, state)

      {:park, reason} ->
        park(op, claim_id, :parked_by_handler, %{reason: inspect(reason, limit: 5)}, state)

      other ->
        park(op, claim_id, :invalid_verdict, %{verdict: inspect(other, limit: 3)}, state)
    end
  end

  defp checkpoint(op, claim_id, data, state) do
    with :ok <-
           ledger_call(state, fn ->
             Alto.OperationLog.record_checkpoint(ledger(state), op, claim_id, data)
           end) do
      ack_quietly(state, claim_id)
      :checkpointed
    else
      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  defp apply_run_verdict(op, claim_id, result, state) do
    evidence = %{run_id: result.run_id, events_dropped: result.events_dropped}

    case result.verdict do
      class when class in [:completed, :rejected_before_dispatch, :failed_known, :unknown] ->
        decide(op, claim_id, class, evidence, state)

      :empty ->
        park(op, claim_id, :empty_run_verdict, evidence, state)
    end
  end

  # Terminal: outcome first, ack second. Ack failures only strand work the
  # ledger already describes, so they log and move on.
  defp decide(op, claim_id, class, evidence, state) do
    case ledger_call(state, fn ->
           Alto.OperationLog.record_outcome(ledger(state), op, claim_id, class, evidence)
         end) do
      :ok ->
        ack_quietly(state, claim_id)
        {:decided, class}

      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  defp park(op, claim_id, reason, evidence, state) do
    with :ok <-
           ledger_call(state, fn ->
             Alto.OperationLog.record_attempt(ledger(state), op, claim_id)
           end),
         :ok <-
           ledger_call(state, fn ->
             Alto.OperationLog.record_outcome(
               ledger(state),
               op,
               claim_id,
               :requires_operator,
               Map.put(evidence, :park_reason, reason)
             )
           end) do
      ack_quietly(state, claim_id)
      :parked
    else
      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  defp park_existing(op, claim_id, attempt_id, reason, evidence, state) do
    case ledger_call(state, fn ->
           Alto.OperationLog.record_outcome(
             ledger(state),
             op,
             attempt_id,
             :requires_operator,
             Map.put(evidence, :park_reason, reason)
           )
         end) do
      :ok ->
        # The current queue claim is acknowledged only after the unresolved
        # operation has been durably parked under its original attempt.
        :ok = ack_quietly(state, claim_id)
        :parked

      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  defp retry(op, claim_id, state) do
    with :ok <-
           ledger_call(state, fn ->
             Alto.OperationLog.record_release(ledger(state), op, claim_id)
           end),
         :ok <- queue_call(state, fn -> Alto.Queue.release(state.queue, claim_id) end) do
      :released
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ack_quietly(state, claim_id) do
    case queue_call(state, fn -> Alto.Queue.ack(state.queue, claim_id) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto consumer: ack failed: #{inspect(reason, limit: 3)}")
    end

    :ok
  end

  defp release_quietly(state, claim_id) do
    case queue_call(state, fn -> Alto.Queue.release(state.queue, claim_id) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto consumer: release failed: #{inspect(reason, limit: 3)}")
    end

    :ok
  end

  defp ledger_status(state, op) do
    ledger_call(state, fn -> Alto.OperationLog.status(ledger(state), op) end)
  end

  defp ledger_call(_state, fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp queue_call(_state, fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  defp ledger(state), do: state.ledger

  defp operation_key(%{operation_key: op}) when is_binary(op), do: op
  defp operation_key(%{admission: :delivery, key: key}), do: key

  defp operation_key(%{generation_id: generation_id}),
    do: "business-generation:" <> generation_id
end
