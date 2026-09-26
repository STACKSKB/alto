defmodule Alto.Consumer do
  @moduledoc """
  Polls a bounded queue, handles each claim, records its outcome in
  `Alto.OperationLog`, then acknowledges or releases the claim. A decided
  outcome is acknowledged without re-running; a dispatched attempt with no
  outcome is parked because it may have committed. Fresh or intended work
  starts a counted attempt. Unknown results and exhausted attempts park;
  explicit retries release the claim and record that release in the ledger.

  Outcome recording precedes acknowledgement. A failed ledger write leaves
  the claim live. Queue claim IDs fence stale workers, and an expired lease is
  reconciled through the ledger rather than blindly replayed. The handler is
  bounded by `handle_timeout`, so a stuck handler blocks only its worker.

  A handler returns:

      handler.(payload, %{operation_key: key, claim_id: id, attempt: n}) ::
        :done | {:done, evidence} | {:failed, reason} |
        {:retry, reason} | {:park, reason} | {:run, runner_result} |
        {:outcome, outcome_class, evidence}

  `evidence` is a map scrubbed by the ledger. `{:run, result}` retains the
  runner's authoritative verdict after its events have been evicted.
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
  Start a consumer with required `:queue`, `:ledger`, and `:handler` options.
  Optional `:by` (`"consumer"`), `:tool` (`"consumer_handler"`),
  `:max_attempts` (3), `:poll_ms` (250),
  `:claim_bytes` (256 KiB), `:batch` (1), `:handle_timeout` (60 seconds),
  and `:autostart` (true) control polling and handling.
  `:name` registers the process. Set `autostart: false` to drive `poll/1`
  manually.
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

    result =
      with {:ok, recovery} <- recover_record(record, op, state) do
        case recovery.status do
          {:intended} ->
            dispatch(op, claim_id, record.payload, recovery, state)

          {:checkpointed, _checkpoint, _attempt} ->
            {:ack, :acked_checkpoint}

          {:dispatched, attempt} ->
            park(op, claim_id, :previous_attempt_unknown, %{prior: :dispatched}, state, attempt)

          {:decided, class, _evidence}
          when record.admission == :recovery and class in [:unknown, :requires_operator] ->
            {:release, :awaiting_reconciliation}

          {:decided, :unknown, _evidence} ->
            {:ack, :parked_unknown}

          {:decided, _class, _evidence} ->
            {:ack, :acked_decided}
        end
      end

    settle_claim(result, claim_id, state)
  end

  # Fresh intent or a released retry: count attempts, then run.
  defp dispatch(op, claim_id, payload, recovery, state) do
    attempt_n = max(recovery.attempts - length(recovery.checkpointed_attempts), 0)

    if attempt_n >= state.max_attempts do
      park(op, claim_id, :attempts_exhausted, %{}, state)
    else
      with :ok <-
             ledger_call(fn -> Alto.OperationLog.record_attempt(state.ledger, op, claim_id) end),
           do: run_handler(op, claim_id, attempt_n + 1, payload, state)
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
    case normalize_verdict(verdict) do
      {:decide, class, evidence} -> decide(op, claim_id, class, evidence, state)
      :retry -> retry(op, claim_id, state)
      {:checkpoint, data} -> checkpoint(op, claim_id, data, state)
      {:park, reason, evidence} -> park(op, claim_id, reason, evidence, state)
    end
  end

  defp normalize_verdict(:done), do: {:decide, :completed, %{}}

  defp normalize_verdict({:done, evidence}) when is_map(evidence),
    do: {:decide, :completed, evidence}

  defp normalize_verdict({:failed, reason}),
    do: {:decide, :failed_known, %{reason: inspect(reason, limit: 5)}}

  defp normalize_verdict({:outcome, class, evidence})
       when class in [:completed, :rejected_before_dispatch, :failed_known, :unknown] and
              is_map(evidence),
       do: {:decide, class, evidence}

  defp normalize_verdict({:retry, _reason}), do: :retry
  defp normalize_verdict({:checkpoint, data}) when is_map(data), do: {:checkpoint, data}

  defp normalize_verdict({:park, reason}),
    do: {:park, :parked_by_handler, %{reason: inspect(reason, limit: 5)}}

  defp normalize_verdict({:run, %Alto.Runner.Result{} = result}) do
    evidence = %{run_id: result.run_id, events_dropped: result.events_dropped}

    case result.verdict do
      class when class in [:completed, :rejected_before_dispatch, :failed_known, :unknown] ->
        {:decide, class, evidence}

      :empty ->
        {:park, :empty_run_verdict, evidence}
    end
  end

  defp normalize_verdict(other),
    do: {:park, :invalid_verdict, %{verdict: inspect(other, limit: 3)}}

  defp checkpoint(op, claim_id, data, state) do
    settle_ledger(:checkpointed, fn ->
      Alto.OperationLog.record_checkpoint(state.ledger, op, claim_id, data)
    end)
  end

  # Terminal: outcome first, ack second. Ack failures only strand work the
  # ledger already describes, so they log and move on.
  defp decide(op, claim_id, class, evidence, state) do
    settle_ledger({:decided, class}, fn ->
      Alto.OperationLog.record_outcome(state.ledger, op, claim_id, class, evidence)
    end)
  end

  # An unknown prior dispatch belongs to its original attempt. Other parked
  # outcomes belong to the current claim, which first needs an attempt line.
  defp park(op, claim_id, reason, evidence, state, original_attempt \\ nil) do
    attempt = original_attempt || claim_id

    settle_ledger(:parked, fn ->
      with :ok <-
             if(original_attempt,
               do: :ok,
               else: Alto.OperationLog.record_attempt(state.ledger, op, claim_id)
             ) do
        Alto.OperationLog.record_outcome(
          state.ledger,
          op,
          attempt,
          :requires_operator,
          Map.put(evidence, :park_reason, reason)
        )
      end
    end)
  end

  defp retry(op, claim_id, state) do
    case ledger_call(fn -> Alto.OperationLog.record_release(state.ledger, op, claim_id) end) do
      :ok -> {:release, :released}
      error -> {:retain, error}
    end
  end

  defp queue_quietly(state, claim_id, action) do
    case queue_call(fn -> apply(Alto.Queue, action, [state.queue, claim_id]) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto consumer: #{action} failed: #{inspect(reason, limit: 3)}")
    end

    :ok
  end

  defp settle_ledger(success, fun) do
    with :ok <- ledger_call(fun), do: {:ack, success}
  end

  defp settle_claim({:retain, result}, _claim_id, _state), do: result

  defp settle_claim({:release, :released}, claim_id, state) do
    with :ok <- queue_call(fn -> Alto.Queue.release(state.queue, claim_id) end), do: :released
  end

  defp settle_claim({action, success}, claim_id, state) when action in [:ack, :release] do
    queue_quietly(state, claim_id, action)
    success
  end

  defp settle_claim({:error, _} = error, claim_id, state) do
    queue_quietly(state, claim_id, :release)
    error
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
