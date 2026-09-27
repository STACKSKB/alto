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
        {:outcome, outcome_class, evidence} | {:checkpoint, packet} |
        :retry | %Alto.Runner.Result{}

  `evidence` is a map scrubbed by the ledger. Use `:requires_operator` to park.
  A runner result retains its authoritative verdict after events have been evicted.
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
    Alto.Queue.request(state.queue, {:claim, state.batch, state.by, state.claim_bytes, :all})
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
             ledger_call(fn ->
               Alto.OperationLog.request(state.ledger, {:attempt, op, claim_id})
             end),
           do: run_handler(op, claim_id, attempt_n + 1, payload, state)
    end
  end

  defp recover_record(record, op, state) do
    ledger_call(fn ->
      case Alto.OperationLog.request(state.ledger, {:recovery, op}) do
        {:error, :not_found} ->
          with :ok <-
                 Alto.OperationLog.request(
                   state.ledger,
                   {:intent, op, state.tool, record.key,
                    %{
                      key: record.key,
                      generation_id: record.generation_id,
                      payload: record.payload
                    }}
                 ) do
            Alto.OperationLog.request(state.ledger, {:recovery, op})
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
      {:error, {:participant_failed, :timeout}} ->
        park(op, claim_id, :handler_timeout, %{timeout_ms: state.handle_timeout}, state)

      {:error, {:participant_failed, reason}} ->
        park(op, claim_id, :handler_crashed, %{error: inspect(reason, limit: 3)}, state)

      verdict ->
        apply_verdict(op, claim_id, verdict, state)
    end
  end

  defp apply_verdict(op, claim_id, verdict, state) do
    {command, action, success} =
      case normalize_verdict(verdict) do
        :retry ->
          {{:release, op, claim_id}, :release, :released}

        {:checkpoint, data} ->
          {{:checkpoint, op, claim_id, data}, :ack, :checkpointed}

        {:outcome, class, evidence} ->
          success = if class == :requires_operator, do: :parked, else: {:decided, class}
          {{:outcome, op, claim_id, class, evidence}, :ack, success}
      end

    case ledger_call(fn -> Alto.OperationLog.request(state.ledger, command) end) do
      :ok -> {action, success}
      error when action == :release -> {:retain, error}
      error -> error
    end
  end

  defp normalize_verdict({:outcome, class, evidence} = verdict)
       when class in [
              :completed,
              :rejected_before_dispatch,
              :failed_known,
              :unknown,
              :requires_operator
            ] and is_map(evidence),
       do: verdict

  defp normalize_verdict(:retry), do: :retry
  defp normalize_verdict({:checkpoint, data} = verdict) when is_map(data), do: verdict

  defp normalize_verdict(%Alto.Runner.Result{} = result) do
    evidence = %{run_id: result.run_id, events_dropped: result.events_dropped}

    if result.verdict == :empty,
      do: {:outcome, :requires_operator, Map.put(evidence, :park_reason, :empty_run_verdict)},
      else: normalize_verdict({:outcome, result.verdict, evidence})
  end

  defp normalize_verdict(other),
    do:
      {:outcome, :requires_operator,
       %{park_reason: :invalid_verdict, verdict: inspect(other, limit: 3)}}

  # A prior unknown dispatch keeps its original attempt. All other parked work
  # first ensures the current counted attempt, including exhaustion before handling.
  defp park(op, claim_id, reason, evidence, state, original_attempt \\ nil) do
    attempt = original_attempt || claim_id

    with :ok <-
           ledger_call(fn ->
             if original_attempt,
               do: :ok,
               else: Alto.OperationLog.request(state.ledger, {:attempt, op, claim_id})
           end) do
      apply_verdict(
        op,
        attempt,
        {:outcome, :requires_operator, Map.put(evidence, :park_reason, reason)},
        state
      )
    end
  end

  defp settle_claim({:retain, result}, _claim_id, _state), do: result

  defp settle_claim(result, claim_id, state) do
    {action, success} =
      case result do
        {:error, _} -> {:release, result}
        {action, success} -> {action, success}
      end

    case queue_call(fn -> Alto.Queue.request(state.queue, {:settle, claim_id, action, []}) end) do
      :ok ->
        success

      error when success == :released ->
        error

      {:error, reason} ->
        Logger.warning("alto consumer: #{action} failed: #{inspect(reason, limit: 3)}")
        success
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
