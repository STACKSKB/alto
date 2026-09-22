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
  Handlers built on `Alto.run/2` can return `{:run, result}` to persist its
  authoritative verdict, which remains valid after retained events are evicted.
  """

  use GenServer

  require Logger

  @options [
    queue: [type: :any, required: true],
    ledger: [type: :any, required: true],
    handler: [type: {:fun, 2}, required: true],
    by: [type: :any, default: "consumer"],
    tool: [type: :string, default: "consumer_handler"],
    max_attempts: [type: :non_neg_integer, default: 3],
    poll_ms: [type: :non_neg_integer, default: 250],
    claim_bytes: [type: :pos_integer, default: 262_144],
    handle_timeout: [type: :pos_integer, default: 60_000],
    batch: [type: :pos_integer, default: 1],
    autostart: [type: :boolean, default: true]
  ]
  @options_schema NimbleOptions.new!(@options)

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

  ## Server implementation

  @impl true
  def init(opts) do
    case NimbleOptions.validate(Keyword.take(opts, Keyword.keys(@options)), @options_schema) do
      {:ok, settings} ->
        {autostart, settings} = Keyword.pop!(settings, :autostart)
        state = Map.new(settings)
        if autostart, do: schedule_tick(state.poll_ms)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, cycle(state), state}

  @impl true
  def handle_info(:tick, state) do
    cycle(state)
    schedule_tick(state.poll_ms)
    {:noreply, state}
  end

  defp schedule_tick(poll_ms), do: Process.send_after(self(), :tick, poll_ms)

  ## One cycle

  defp cycle(state) do
    case guarded_claim(state) do
      {:error, reason} ->
        Logger.warning("alto consumer: claim failed: #{inspect(reason, limit: 3)}")
        {:error, reason}

      {:ok, []} ->
        :idle

      {:ok, records} ->
        {:handled, Enum.map(records, &handle_record(&1, state))}
    end
  end

  defp guarded_claim(state) do
    Alto.Queue.claim_bounded(state.queue, state.batch, state.by, state.claim_bytes)
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end

  defp handle_record(record, state) do
    op = record.operation_key
    claim_id = record.claim_id

    with {:ok, recovery} <- recover_record(record, op, state) do
      case recovery.status do
        {:intended} ->
          dispatch(op, claim_id, record.payload, recovery, state)

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
    else
      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  # Fresh intent or a released retry: count attempts, then run.
  defp dispatch(op, claim_id, payload, recovery, state) do
    attempt_n = max(recovery.attempts - length(recovery.checkpointed_attempts), 0)

    if attempt_n >= state.max_attempts do
      park(op, claim_id, :attempts_exhausted, %{}, state)
    else
      case ledger_call(fn -> Alto.OperationLog.record_attempt(state.ledger, op, claim_id) end) do
        :ok ->
          run_handler(op, claim_id, attempt_n + 1, payload, state)

        {:error, reason} ->
          release_quietly(state, claim_id)
          {:error, reason}
      end
    end
  end

  defp recover_record(record, op, state) do
    ledger_call(fn ->
      case Alto.OperationLog.recovery(state.ledger, op) do
        {:error, :not_found} ->
          with :ok <-
                 Alto.OperationLog.record_intent(
                   state.ledger,
                   op,
                   state.tool,
                   record.key,
                   %{
                     key: record.key,
                     generation_id: record.generation_id,
                     payload: record.payload
                   }
                 ) do
            Alto.OperationLog.recovery(state.ledger, op)
          end

        result ->
          result
      end
    end)
  end

  # The shared invocation boundary kills handlers on timeout or owner death.
  # A participant crash is uncertainty to persist, not a consumer crash.
  defp run_handler(op, claim_id, attempt_n, payload, state) do
    outcome =
      Alto.Runner.Execution.Call.run(
        fn ->
          state.handler.(payload, %{
            key: op,
            operation_key: op,
            claim_id: claim_id,
            attempt: attempt_n
          })
        end,
        state.handle_timeout,
        nil
      )

    case outcome do
      {:ok, verdict} ->
        apply_verdict(op, claim_id, verdict, state)

      {:error, :timeout} ->
        park(op, claim_id, :handler_timeout, %{timeout_ms: state.handle_timeout}, state)

      {:error, reason} ->
        park(op, claim_id, :handler_crashed, %{error: inspect(reason, limit: 3)}, state)
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

      {:run, %Alto.Runner.Result{} = result} ->
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
    result =
      ledger_call(fn ->
        Alto.OperationLog.record_checkpoint(state.ledger, op, claim_id, data)
      end)

    settle_claim(result, :checkpointed, claim_id, state)
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
    result =
      ledger_call(fn ->
        Alto.OperationLog.record_outcome(state.ledger, op, claim_id, class, evidence)
      end)

    settle_claim(result, {:decided, class}, claim_id, state)
  end

  defp park(op, claim_id, reason, evidence, state) do
    result =
      ledger_call(fn ->
        with :ok <- Alto.OperationLog.record_attempt(state.ledger, op, claim_id) do
          Alto.OperationLog.record_outcome(
            state.ledger,
            op,
            claim_id,
            :requires_operator,
            Map.put(evidence, :park_reason, reason)
          )
        end
      end)

    settle_claim(result, :parked, claim_id, state)
  end

  defp park_existing(op, claim_id, attempt_id, reason, evidence, state) do
    # The current queue claim is acknowledged only after the unresolved
    # operation has been durably parked under its original attempt.
    result =
      ledger_call(fn ->
        Alto.OperationLog.record_outcome(
          state.ledger,
          op,
          attempt_id,
          :requires_operator,
          Map.put(evidence, :park_reason, reason)
        )
      end)

    settle_claim(result, :parked, claim_id, state)
  end

  defp retry(op, claim_id, state) do
    with :ok <-
           ledger_call(fn ->
             Alto.OperationLog.record_release(state.ledger, op, claim_id)
           end),
         :ok <- queue_call(fn -> Alto.Queue.release(state.queue, claim_id) end) do
      :released
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ack_quietly(state, claim_id), do: queue_quietly(state, claim_id, :ack)
  defp release_quietly(state, claim_id), do: queue_quietly(state, claim_id, :release)

  defp queue_quietly(state, claim_id, action) do
    case queue_call(fn -> apply(Alto.Queue, action, [state.queue, claim_id]) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto consumer: #{action} failed: #{inspect(reason, limit: 3)}")
    end

    :ok
  end

  defp settle_claim(result, success, claim_id, state) do
    case result do
      :ok ->
        ack_quietly(state, claim_id)
        success

      {:error, reason} ->
        release_quietly(state, claim_id)
        {:error, reason}
    end
  end

  defp ledger_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:ledger_unavailable, reason}}
  end

  defp queue_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:queue_unavailable, reason}}
  end
end
