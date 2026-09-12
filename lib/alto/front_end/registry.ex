defmodule Alto.FrontEnd.Registry do
  @moduledoc """
  The resident-side hub between the execution host and front-end transports.

  The registry owns run lifetimes started through it, assigns provisional
  per-run durable sequence numbers (the protocol contract: the session store will assign
  final ones later), retains a bounded durable replay buffer per run, and
  correlates front-end approval decisions. It is transport-agnostic: it ships
  typed notifications to subscriber processes, which encode them through
  `Alto.Protocol` for their own wire.

  Delivery is pull-based: subscribers receive notifications only in response
  to `pull/3`, so a stalled client stops pulling and consumes at most its
  configured buffer. When a subscriber's buffer is full, incoming
  notifications are dropped and an `overflow` notification is queued for the
  next pull — durable gaps are never silent. The core itself is never blocked
  by a slow client.

  Approval notifications ignore domain filters: any client attached to a run
  is eligible to answer its approvals, and the first decision wins. Handles
  are globally unique operations (`"<run_id>:op-<seq>"`, ): no scoping or
  random-suffix patch, every request/response/event/cleanup path uses the
  handle, and `call_id` is correlation only. Pending approvals replay on
  `attach` for reconnect; duplicate handles fail `already_pending` and late
  replies fail `not_found`.

  Finished runs keep their replay buffers up to a bounded recent window
  (`:max_finished_runs`, default 100); `run_ids/1` lists only live runs.
  Once the window is exceeded the oldest finished run is evicted and a later
  `attach` to it answers `unknown_run` — webhook-per-event traffic would
  otherwise grow the registry monotonically.
  """

  use GenServer

  alias Alto.Approval.Request, as: ApprovalRequest
  alias Alto.Event
  alias Alto.Runner

  @enforce_keys [:id, :handle, :completion_ref]
  defstruct [
    :id,
    :handle,
    :completion_ref,
    :session_id,
    :task_preview,
    :config_name,
    :started_at_ms,
    :start_order,
    events_rev: [],
    head_seq: 0,
    status: :running,
    result: nil,
    pending: %{}
  ]

  defmodule Subscriber do
    @enforce_keys [:pid, :monitor, :runs, :domains, :max_buffer_messages]
    defstruct [
      :pid,
      :monitor,
      :runs,
      :domains,
      :max_buffer_messages,
      buffer: {[], []},
      buffered_count: 0,
      buffered_bytes: 0,
      max_buffer_bytes: 8_000_000,
      overflow: [],
      last_durable_seq: %{},
      closed?: false
    ]
  end

  @default_max_buffer_messages 10_000
  @default_max_retained_events 1_000
  @default_max_finished_runs 100
  @default_max_claim_bytes 1_046_528
  @max_task_bytes 1_000_000

  ## Client API

  @doc """
  Start the registry. Options:

    * `:config_resolver` — required fun taking a configuration name and
      returning `{:ok, run_opts}` or `{:error, term()}`;
    * `:cwd` — workspace root for started runs (default: `File.cwd!/0`);
    * `:queue` — optional durable queue server (`Alto.Queue`) backing the
      claim/ack surface;
    * `:ledger` — optional operation ledger server (`Alto.OperationLog`)
      backing the read-only operator inspection surface (`ops_list`);
      the queue/ledger pair is read together, never written by inspection;
    * `:max_buffer_messages` — per-subscriber notification bound;
    * `:max_retained_events` — durable replay bound per run;
    * `:max_finished_runs` — finished-run replay window (default 100);
    * `:max_claim_bytes` — encoded-bytes budget for `queue_claim` replies
      without an explicit per-call budget (default 1 MiB minus envelope
      reserve); transports pass their own `max_line_bytes`-derived budget
      per call so claims never outgrow the connection;
    * :commands — optional map of non-empty binary names to trusted arity-one
      callbacks. A callback receives a map and returns a map, {:ok, map()},
      or {:error, reason}; it runs in a supervised task;
    * `:command_timeout` — callback deadline in milliseconds (default 30,000).
      A timeout reports an unknown outcome; callers must reconcile before retrying;
    * `:disconnect_after_overflow` — `:never` (default) or `:immediately`;
    * `:sessions` — served-run session persistence (, explicit opt-in,
      default `false` keeps served runs unpersisted): `true` persists each
      fresh run in the default session store, `[session_dir: path]` uses a
      custom directory. Resume (`start_run` with `resume:`) reads from the
      same directory regardless of this flag. Evicting a finished run from
      the replay window never deletes its session files;
    * `:session_dir` — session directory override (default: the standard
      session store); also honoured when `sessions:` carries no directory;
    * `:name` — registered name (default `Alto.FrontEnd.Registry`).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Start a run from a trusted, resolver-resolvable configuration name. An
  optional owner pid may be supplied in opts; it receives the runner's
  cancellation guarantee, while the registry process is the default owner.

  Options: `:resume` — continue a persisted session id instead of starting
  fresh. The session must exist with a resumable (completed-run) transcript
  snapshot; crashed runs report `:no_resumable_transcript` rather than
  rerunning anything. Provider, tools, approval, and bounds come from the
  resolved configuration exactly like a fresh run.
  """
  @spec start_run(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_run(server \\ __MODULE__, config_name, task, opts \\ []) do
    GenServer.call(server, {:start_run, config_name, task, opts})
  end

  @doc "Return the authoritative stored runner return for a run."
  @spec run_result(GenServer.server(), String.t()) ::
          :running | {:ok, Runner.outcome()} | {:error, :unknown_run}
  def run_result(server \\ __MODULE__, run_id) do
    GenServer.call(server, {:run_result, run_id})
  end

  @doc "Invoke a trusted, configured application command callback."
  @spec command(GenServer.server(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def command(server \\ __MODULE__, name, payload)

  def command(server, name, payload) when is_binary(name) and is_map(payload) do
    with {:ok, callback, timeout} <- GenServer.call(server, {:command_callback, name}) do
      case Alto.Runner.Execution.Support.supervised_call(
             fn -> invoke_command(callback, payload) end,
             timeout,
             nil
           ) do
        {:ok, result} -> result
        {:error, reason} -> {:error, {:command_outcome_unknown, reason}}
      end
    end
  end

  def command(_server, _name, _payload), do: {:error, :invalid_command}

  defp invoke_command(callback, payload) do
    case callback.(payload) do
      result when is_map(result) -> {:ok, result}
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_command_result}
    end
  rescue
    exception -> {:error, {:command_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:command_throw, kind, reason}}
  end

  @doc "The session id owning a run, or `nil` when the run is unpersisted."
  @spec run_session(GenServer.server(), String.t()) :: String.t() | nil
  def run_session(server \\ __MODULE__, run_id) do
    GenServer.call(server, {:run_session, run_id})
  end

  @doc """
  Resumable-session summaries (discovery), newest first, from the
  registry's session directory — independent of the live-run replay window,
  so evicted and restarted-away runs stay discoverable.
  """
  @spec sessions(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def sessions(server \\ __MODULE__) do
    GenServer.call(server, :sessions)
  end

  @doc "Read a bounded page of durable session events, independent of live runs."
  @spec session_events(
          GenServer.server(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          String.t() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def session_events(server \\ __MODULE__, session_id, limit, cursor, run_id \\ nil) do
    GenServer.call(server, {:session_events, session_id, limit, cursor, run_id})
  end

  @doc "Read the latest 100 messages from a persisted session transcript."
  @spec session_transcript(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def session_transcript(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:session_transcript, session_id})
  end

  @doc "Bounded resident run summaries for reconnecting front ends."
  def runs(server \\ __MODULE__), do: GenServer.call(server, :runs)

  @doc "Live run ids, for the `hello` message."
  @spec run_ids(GenServer.server()) :: [String.t()]
  def run_ids(server \\ __MODULE__) do
    GenServer.call(server, :run_ids)
  end

  @doc """
  Subscribe a client process. A `nil` `run_id` subscribes to all present and
  future runs without replay; a named run replays its durable log from
  `from_seq` (inclusive) in an `attached` notification, followed by its
  `result` if the run has finished — once per connection.
  """
  @spec attach(GenServer.server(), pid(), String.t() | nil, pos_integer(), [atom()]) ::
          :ok | {:error, :unknown_run}
  def attach(server \\ __MODULE__, client_pid, run_id, from_seq, domains) do
    GenServer.call(server, {:attach, client_pid, run_id, from_seq, domains})
  end

  @doc "Drop a client's subscriptions and buffered notifications."
  @spec detach(GenServer.server(), pid()) :: :ok
  def detach(server \\ __MODULE__, client_pid) do
    GenServer.call(server, {:detach, client_pid})
  end

  @doc "Cooperatively cancel a run; any known run replies ok."
  @spec cancel(GenServer.server(), String.t(), term()) :: :ok | {:error, :unknown_run}
  def cancel(server \\ __MODULE__, run_id, reason) do
    GenServer.call(server, {:cancel, run_id, reason})
  end

  @doc "Register a run's policy process as the waiter for one approval request."
  @spec request_approval(GenServer.server(), String.t(), ApprovalRequest.t(), pid()) ::
          :ok | {:error, term()}
  def request_approval(server \\ __MODULE__, session_id, %ApprovalRequest{} = request, waiter) do
    GenServer.call(server, {:request_approval, session_id, request, waiter})
  end

  @doc """
  Deliver a front-end approval decision. The first decision for a request
  wins; later ones return `{:error, :not_found}`. The run's `approval_resolved`
  notification is emitted by the host's own live event, which keeps every
  deny/timeout/cancel path on one publication route.
  """
  @spec approval_response(GenServer.server(), String.t(), :approve | {:deny, term()}) ::
          :ok | {:error, :not_found}
  def approval_response(server \\ __MODULE__, request_id, decision) do
    GenServer.call(server, {:approval_response, request_id, decision})
  end

  @doc """
  Claim pending records from the registry's configured durable queue
  (`:queue` start option). `{:error, :no_queue}` when none is configured —
  the job-flow surface (the integration contract) for the pull/ack half.

  Claims are bounded by count *and* encoded bytes: at most `count` records
  whose wire form fits in `max_bytes` (default: the registry's
  `:max_claim_bytes`). A lone oversized head answers
  `{:error, {:record_too_large, %{id:, key:, size:}}}` with nothing leased.
  """
  @spec queue_claim(GenServer.server(), pos_integer(), term(), non_neg_integer() | nil) ::
          {:ok, [map()]} | {:error, :no_queue | term()}
  def queue_claim(server \\ __MODULE__, count, by, max_bytes \\ nil) do
    GenServer.call(server, {:queue_claim, count, by, max_bytes})
  end

  @doc "Blank a claimed queue record (it was handled — 'these records are processed')."
  @spec queue_ack(GenServer.server(), String.t()) :: :ok | {:error, :no_queue | term()}
  def queue_ack(server \\ __MODULE__, claim_id) do
    GenServer.call(server, {:queue_ack, claim_id})
  end

  @doc "Return a claim to pending (the client failed before finishing)."
  @spec queue_release(GenServer.server(), String.t()) :: :ok | {:error, :no_queue | term()}
  def queue_release(server \\ __MODULE__, claim_id) do
    GenServer.call(server, {:queue_release, claim_id})
  end

  @doc """
  Bounded read-only operator inspection (`Alto.Ops.list/3`) over the
  registry's configured queue and ledger. `{:error, :no_ops}` when either
  is unconfigured — inspection reads the pair together and never writes.
  Unknown work is never marked safely retryable; recovery stays with the
  existing queue/ledger calls under their own identities.
  """
  @spec ops_list(GenServer.server(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: integer() | nil}} | {:error, :no_ops | term()}
  def ops_list(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:ops_list, opts})
  end

  @doc """
  Grant the client up to `count` buffered notifications. The core only ever
  sends to a client in response to a pull, so a stalled client stops consuming
  registry memory at its configured buffer.
  """
  @spec pull(GenServer.server(), pid(), pos_integer()) :: :ok
  def pull(server \\ __MODULE__, client_pid, count) do
    GenServer.cast(server, {:pull, client_pid, count})
  end

  ## Server implementation

  @impl true
  def init(opts) do
    {sessions_enabled, session_dir} = normalize_sessions(opts)

    state = %{
      resolver: Keyword.fetch!(opts, :config_resolver),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      queue: Keyword.get(opts, :queue),
      ledger: Keyword.get(opts, :ledger),
      max_buffer_messages: Keyword.get(opts, :max_buffer_messages, @default_max_buffer_messages),
      max_buffer_bytes: Keyword.get(opts, :max_buffer_bytes, 8_000_000),
      max_active_runs: Keyword.get(opts, :max_active_runs, 32),
      max_subscribers: Keyword.get(opts, :max_subscribers, 128),
      max_retained_events: Keyword.get(opts, :max_retained_events, @default_max_retained_events),
      max_finished_runs: Keyword.get(opts, :max_finished_runs, @default_max_finished_runs),
      max_claim_bytes: Keyword.get(opts, :max_claim_bytes, @default_max_claim_bytes),
      commands: Keyword.get(opts, :commands, %{}),
      command_timeout: Keyword.get(opts, :command_timeout, 30_000),
      sessions_enabled: sessions_enabled,
      session_dir: session_dir,
      disconnect_after_overflow:
        validate_disconnect(Keyword.get(opts, :disconnect_after_overflow, :never)),
      subscribers: %{},
      runs: %{},
      finished_order: []
    }

    with :ok <- validate_capacity_options(state),
         :ok <- validate_max_finished_runs(state.max_finished_runs),
         :ok <- validate_max_claim_bytes(state.max_claim_bytes),
         :ok <- validate_commands(state.commands),
         :ok <- validate_command_timeout(state.command_timeout) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Served-run persistence is explicit: fresh runs persist only when the
  # operator opts in. Resume reads the session directory either way.
  defp normalize_sessions(opts) do
    dir =
      case Keyword.get(opts, :sessions) do
        [_ | _] = sessions_opts -> Keyword.get(sessions_opts, :session_dir)
        _other -> nil
      end

    dir = dir || Keyword.get(opts, :session_dir) || Alto.Session.dir()
    enabled = Keyword.get(opts, :sessions, false) != false

    {enabled, dir}
  end

  defp validate_max_claim_bytes(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_max_claim_bytes(n), do: {:error, {:invalid_max_claim_bytes, n}}

  defp validate_owner(owner) when is_pid(owner), do: :ok
  defp validate_owner(owner), do: {:error, {:invalid_owner, owner}}

  defp validate_command_timeout(value) when is_integer(value) and value > 0, do: :ok
  defp validate_command_timeout(value), do: {:error, {:invalid_option, :command_timeout, value}}

  defp validate_commands(commands) when is_map(commands) do
    if Enum.all?(commands, fn {name, callback} ->
         is_binary(name) and name != "" and is_function(callback, 1)
       end) do
      :ok
    else
      {:error, {:invalid_option, :commands, commands}}
    end
  end

  defp validate_commands(commands), do: {:error, {:invalid_option, :commands, commands}}

  defp validate_max_finished_runs(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_max_finished_runs(n), do: {:error, {:invalid_max_finished_runs, n}}

  defp validate_disconnect(:never), do: :never

  defp validate_disconnect(:immediately), do: :immediately

  defp validate_disconnect(other),
    do: raise(ArgumentError, "invalid disconnect_after_overflow: #{inspect(other)}")

  defp validate_capacity_options(state) do
    keys = [
      :max_buffer_messages,
      :max_buffer_bytes,
      :max_retained_events,
      :max_active_runs,
      :max_subscribers
    ]

    case Enum.find(keys, fn key -> not is_integer(state[key]) or state[key] < 0 end) do
      nil -> :ok
      key -> {:error, {:invalid_option, key, state[key]}}
    end
  end

  defp active_capacity(state) do
    count = Enum.count(state.runs, fn {_id, run} -> run.status == :running end)
    if count < state.max_active_runs, do: :ok, else: {:error, :run_capacity}
  end

  @impl true
  def handle_call({:start_run, config_name, task, opts}, _from, state) do
    owner = Keyword.get(opts, :owner, self())

    with :ok <- validate_owner(owner),
         :ok <- active_capacity(state),
         :ok <- validate_task(task),
         {:ok, config_opts} <- resolve_config(state.resolver, config_name),
         {:ok, session_opts} <- execution_session_opts(opts, config_opts, state) do
      run_id = "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      me = self()

      run_opts =
        config_opts
        |> Keyword.merge(Keyword.take(opts, [:continuation_key, :budget_account]))
        |> Keyword.put_new(:cwd, state.cwd)
        |> Keyword.put_new(:project_instructions, :auto)
        |> Keyword.put(:session_id, run_id)
        |> Keyword.put(:owner, owner)
        |> Keyword.put(:tool_context_metadata, %{front_end_registry: me})
        |> Keyword.put(:event_sink, fn event ->
          GenServer.call(me, {:ingest_run_event, run_id, event})
        end)
        |> with_session(session_opts, state)

      case start_observed(task, run_opts) do
        {:ok, handle, completion_ref} ->
          run = %__MODULE__{
            id: run_id,
            handle: handle,
            completion_ref: completion_ref,
            session_id: Keyword.get(session_opts, :session),
            task_preview: String.slice(task, 0, 120),
            config_name: config_name,
            started_at_ms: System.system_time(:millisecond),
            start_order: System.unique_integer([:positive, :monotonic])
          }

          {:reply, {:ok, run_id}, %{state | runs: Map.put(state.runs, run_id, run)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:run_result, run_id}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %{status: :running}} -> {:reply, :running, state}
      {:ok, %{result: result}} -> {:reply, {:ok, result}, state}
      :error -> {:reply, {:error, :unknown_run}, state}
    end
  end

  def handle_call({:command_callback, name}, _from, state) do
    case Map.fetch(state.commands, name) do
      {:ok, callback} -> {:reply, {:ok, callback, state.command_timeout}, state}
      :error -> {:reply, {:error, :unknown_command}, state}
    end
  end

  def handle_call({:run_session, run_id}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> {:reply, run.session_id, state}
      :error -> {:reply, nil, state}
    end
  end

  def handle_call(:sessions, _from, state) do
    {:reply, Alto.Session.list(session_dir: state.session_dir), state}
  end

  def handle_call({:session_events, session_id, limit, cursor, run_id}, _from, state) do
    {:reply,
     Alto.Session.events(session_id,
       session_dir: state.session_dir,
       limit: limit,
       cursor: cursor,
       run_id: run_id
     ), state}
  end

  def handle_call({:session_transcript, session_id}, _from, state) do
    reply =
      with {:ok, transcript} <-
             Alto.Session.transcript(session_id, session_dir: state.session_dir),
           messages = Enum.take(transcript.messages, -100) do
        {:ok,
         %{
           messages: messages,
           revision: transcript.revision,
           truncated: length(messages) < length(transcript.messages)
         }}
      else
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(:runs, _from, state) do
    summaries =
      state.runs
      |> Map.values()
      |> Enum.sort_by(& &1.start_order, :desc)
      |> Enum.map(&run_summary/1)

    {:reply, {:ok, summaries}, state}
  end

  def handle_call(:run_ids, _from, state) do
    live =
      state.runs
      |> Enum.filter(fn {_id, run} -> run.status == :running end)
      |> Enum.map(&elem(&1, 0))

    {:reply, live, state}
  end

  def handle_call({:attach, client_pid, run_id, from_seq, domains}, _from, state) do
    cond do
      map_size(state.subscribers) >= state.max_subscribers ->
        {:reply, {:error, :subscriber_capacity}, state}

      run_id != nil and not Map.has_key?(state.runs, run_id) ->
        {:reply, {:error, :unknown_run}, state}

      Map.has_key?(state.subscribers, client_pid) ->
        {:reply, {:error, :already_attached}, state}

      true ->
        subscriber = %Subscriber{
          pid: client_pid,
          monitor: Process.monitor(client_pid),
          runs: if(run_id, do: MapSet.new([run_id]), else: :all),
          domains: MapSet.new(domains),
          max_buffer_messages: state.max_buffer_messages,
          max_buffer_bytes: state.max_buffer_bytes
        }

        state = %{state | subscribers: Map.put(state.subscribers, client_pid, subscriber)}
        state = deliver_attach(state, subscriber, run_id, from_seq)

        {:reply, :ok, state}
    end
  end

  def handle_call({:detach, client_pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, client_pid)}
  end

  def handle_call({:ingest_run_event, run_id, %Event{} = event}, _from, state) do
    next =
      case Map.fetch(state.runs, run_id) do
        {:ok, run} -> ingest_event(state, run, event)
        :error -> state
      end

    {:reply, :ok, next}
  end

  def handle_call({:cancel, run_id, reason}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} ->
        Runner.cancel(run.handle, reason)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_run}, state}
    end
  end

  # Approval handles are globally unique operation ids: no scoping
  # or random-suffix patch. The handle in `request.id`/`operation_id` is the
  # key; `call_id` is correlation only. A duplicate handle is a caller bug
  # and is rejected instead of silently replacing the waiter.
  def handle_call({:request_approval, session_id, request, waiter}, _from, state)
      when is_binary(request.id) do
    case Map.fetch(state.runs, session_id) do
      :error ->
        {:reply, {:error, :unknown_run}, state}

      {:ok, run} ->
        if Map.has_key?(run.pending, request.id) do
          {:reply, {:error, :already_pending}, state}
        else
          entry = %{
            waiter: waiter,
            monitor: Process.monitor(waiter),
            request: request
          }

          state =
            update_run(state, session_id, fn run ->
              %{run | pending: Map.put(run.pending, request.id, entry)}
            end)

          state = publish(state, run.id, {:approval_request, run.id, request}, :approval)
          {:reply, :ok, state}
        end
    end
  end

  def handle_call({:request_approval, _session_id, _request, _waiter}, _from, state) do
    {:reply, {:error, :unaddressable_request}, state}
  end

  def handle_call({:approval_response, request_id, decision}, _from, state) do
    {reply, state} = resolve_approval(state, request_id, decision)
    {:reply, reply, state}
  end

  def handle_call({:queue_claim, count, by, max_bytes}, _from, state) do
    budget = max_bytes || state.max_claim_bytes

    {:reply, queue_op(state, fn -> Alto.Queue.claim_bounded(state.queue, count, by, budget) end),
     state}
  end

  def handle_call({:queue_ack, claim_id}, _from, state) do
    {:reply, queue_op(state, fn -> Alto.Queue.ack(state.queue, claim_id) end), state}
  end

  def handle_call({:queue_release, claim_id}, _from, state) do
    {:reply, queue_op(state, fn -> Alto.Queue.release(state.queue, claim_id) end), state}
  end

  def handle_call({:ops_list, opts}, _from, state) do
    {:reply, ops_list_op(state, opts), state}
  end

  # A dead or crashing queue must not take the registry — and every
  # unrelated run it owns — down with it. Queue failures stay observable
  # per call.
  defp queue_op(%{queue: nil}, _fun), do: {:error, :no_queue}

  defp queue_op(_state, fun) do
    try do
      fun.()
    rescue
      error -> {:error, {:queue_unavailable, Exception.message(error)}}
    catch
      :exit, reason -> {:error, {:queue_unavailable, reason}}
    end
  end

  # Read-only inspection needs both stores; a dead store answers
  # per-call without taking the registry down. No new authority: this
  # never writes, approves, or acknowledges anything.
  defp ops_list_op(%{queue: nil}, _opts), do: {:error, :no_ops}
  defp ops_list_op(%{ledger: nil}, _opts), do: {:error, :no_ops}

  defp ops_list_op(%{queue: queue, ledger: ledger}, opts) do
    try do
      Alto.Ops.list(queue, ledger, opts)
    rescue
      error -> {:error, {:ops_unavailable, Exception.message(error)}}
    catch
      :exit, reason -> {:error, {:ops_unavailable, reason}}
    end
  end

  @impl true
  def handle_cast({:pull, client_pid, count}, state) do
    case Map.fetch(state.subscribers, client_pid) do
      {:ok, subscriber} ->
        {:noreply, deliver_pull(state, client_pid, subscriber, count)}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:alto_run_event, run_id, %Event{} = event}, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> {:noreply, ingest_event(state, run, event)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:alto_runner_result, ref, outcome}, state) do
    case find_run(state, completion_ref: ref) do
      %{status: :running} = run -> {:noreply, finish_run(state, run, outcome)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, state |> maybe_drop_subscriber(monitor) |> maybe_clear_pending(monitor)}
  end

  defp maybe_drop_subscriber(state, monitor) do
    case find_subscriber(state, monitor: monitor) do
      {pid, _subscriber} -> drop_subscriber(state, pid)
      nil -> state
    end
  end

  defp maybe_clear_pending(state, monitor) do
    case find_pending(state, monitor: monitor) do
      nil -> state
      _found -> clear_pending(state, monitor: monitor)
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.subscribers, fn {pid, _subscriber} -> send(pid, :alto_close) end)
    :ok
  end

  defp run_summary(run) do
    {status, result} =
      case run.status do
        :running -> {"running", nil}
        {:done, {:error, :approval_suspended}, _, _} -> {"suspended", run.result}
        {:done, :ok, _, _} -> {"completed", run.result}
        {:done, {:cancelled, _}, _, _} -> {"cancelled", run.result}
        _ -> {"failed", run.result}
      end

    usage =
      case result do
        {:ok, value} -> value.usage
        {:error, _, value} when not is_nil(value) -> value.usage
        _ -> %{}
      end

    %{
      id: run.id,
      session_id: run.session_id,
      title: run.task_preview,
      config: run.config_name,
      status: status,
      pending_approvals: map_size(run.pending),
      usage: usage,
      started_at_ms: run.started_at_ms
    }
  end

  ## Run events

  defp ingest_event(state, run, %Event{domain: :durable} = event) do
    seq = run.head_seq + 1

    run = %{
      run
      | head_seq: seq,
        events_rev: retain([{seq, event} | run.events_rev], state.max_retained_events)
    }

    state = %{state | runs: Map.put(state.runs, run.id, run)}

    publish(state, run.id, {:event, run.id, seq, event}, :durable)
  end

  defp ingest_event(state, run, %Event{domain: :live} = event) do
    # The approval_request notification is published by request_approval, not
    # here: the host emits approval_requested before the policy task runs, so
    # publishing on the live event would advertise a request no response could
    # yet answer. request_approval publishes and registers the waiter in one
    # call, so an observed approval_request always has a pending waiter.
    state =
      case {event.type, event.data} do
        {:approval_resolved, %{request: %ApprovalRequest{} = request, decision: decision}} ->
          state
          |> clear_pending(request_id: request.id)
          |> publish(run.id, {:approval_resolved, run.id, request, decision}, :approval)

        _other ->
          state
      end

    publish(state, run.id, {:event, run.id, nil, event}, :live)
  end

  defp retain(events, max) when length(events) <= max, do: events
  defp retain(events, max), do: Enum.take(events, max)

  ## Fanout

  # `:durable`/`:live` honor the subscriber's domain filter; approvals and
  # results always reach every client attached to the run.
  defp publish(state, run_id, notification, domain) do
    Enum.reduce(state.subscribers, state, fn {pid, subscriber}, state ->
      if interested?(subscriber, run_id, domain) do
        enqueue(state, pid, subscriber, notification)
      else
        state
      end
    end)
  end

  defp interested?(%Subscriber{runs: :all, domains: domains}, _run_id, domain) do
    domain == :approval or domain == :result or MapSet.member?(domains, domain)
  end

  defp interested?(%Subscriber{runs: runs, domains: domains}, run_id, domain) do
    MapSet.member?(runs, run_id) and
      (domain == :approval or domain == :result or MapSet.member?(domains, domain))
  end

  defp enqueue(state, pid, subscriber, notification) do
    bytes = :erlang.external_size(notification)

    if subscriber.buffered_count >= subscriber.max_buffer_messages or
         subscriber.buffered_bytes + bytes > subscriber.max_buffer_bytes do
      overflow =
        case notification do
          {:event, run_id, seq, _event} when is_integer(seq) ->
            {:durable, run_id, Map.get(subscriber.last_durable_seq, run_id)}

          {:event, run_id, nil, _event} ->
            {:live, run_id, nil}

          _other ->
            {:live, nil, nil}
        end

      markers =
        cond do
          {:durable, nil, nil} in subscriber.overflow -> subscriber.overflow
          overflow in subscriber.overflow -> subscriber.overflow
          length(subscriber.overflow) >= 100 -> [{:durable, nil, nil}, {:live, nil, nil}]
          true -> [overflow | subscriber.overflow]
        end

      subscriber = %{subscriber | overflow: markers}
      %{state | subscribers: Map.put(state.subscribers, pid, subscriber)}
    else
      subscriber = %{
        subscriber
        | buffer: :queue.in({notification, bytes}, subscriber.buffer),
          buffered_count: subscriber.buffered_count + 1,
          buffered_bytes: subscriber.buffered_bytes + bytes
      }

      %{state | subscribers: Map.put(state.subscribers, pid, subscriber)}
    end
  end

  defp deliver_pull(state, client_pid, subscriber, count) do
    taken = min(max(count, 0), subscriber.buffered_count)
    {batch, rest} = :queue.split(taken, subscriber.buffer)
    pairs = :queue.to_list(batch)
    deliveries = Enum.map(pairs, &elem(&1, 0))
    bytes = Enum.reduce(pairs, 0, &(elem(&1, 1) + &2))
    Enum.each(deliveries, &send(client_pid, {:alto_notification, &1}))

    subscriber =
      %{
        subscriber
        | buffer: rest,
          buffered_count: subscriber.buffered_count - taken,
          buffered_bytes: subscriber.buffered_bytes - bytes
      }
      |> note_delivered(deliveries)

    {overflow_batch, rest_overflow} = Enum.split(subscriber.overflow, count)

    overflow_notifications =
      Enum.map(overflow_batch, fn {domain, run_id, last_seq} ->
        {:alto_notification, {:overflow, run_id, domain, last_seq}}
      end)

    Enum.each(overflow_notifications, &send(client_pid, &1))

    subscriber = %{subscriber | overflow: rest_overflow}

    disconnect? =
      state.disconnect_after_overflow == :immediately and overflow_batch != [] and
        not subscriber.closed?

    if disconnect? do
      send(client_pid, :alto_close)
      subscriber = %{subscriber | closed?: true}
      %{state | subscribers: Map.put(state.subscribers, client_pid, subscriber)}
    else
      %{state | subscribers: Map.put(state.subscribers, client_pid, subscriber)}
    end
  end

  defp note_delivered(subscriber, deliveries) do
    last_durable_seq =
      Enum.reduce(deliveries, subscriber.last_durable_seq, fn
        {:event, run_id, seq, _event}, acc when is_integer(seq) ->
          Map.put(acc, run_id, seq)

        _other, acc ->
          acc
      end)

    %{subscriber | last_durable_seq: last_durable_seq}
  end

  ## Attach and replay

  # A wildcard attach subscribes to all present and future runs: replay every
  # running run's pending approvals so a reconnecting client can still answer.
  defp deliver_attach(state, subscriber, nil, _from_seq) do
    Enum.reduce(state.runs, state, fn {run_id, run}, state ->
      if run.status == :running do
        Enum.reduce(run.pending, state, fn {_approval_id, entry}, state ->
          current = Map.fetch!(state.subscribers, subscriber.pid)
          enqueue(state, current.pid, current, {:approval_request, run_id, entry.request})
        end)
      else
        state
      end
    end)
  end

  defp deliver_attach(state, subscriber, run_id, from_seq) do
    run = Map.fetch!(state.runs, run_id)
    dropped = run.head_seq - length(run.events_rev)
    gap = from_seq <= dropped and dropped > 0

    replay =
      run.events_rev
      |> Enum.reverse()
      |> Enum.filter(fn {seq, _event} -> seq >= from_seq end)

    state =
      enqueue(state, subscriber.pid, subscriber, {:attached, run_id, gap, run.head_seq, replay})

    # Reconnect: a client that attaches after an approval was
    # published but before it was decided must still be able to answer it.
    # Pending approvals are live-only, so they are replayed after the
    # durable `attached` envelope on every attach to a running run.
    state =
      if run.status == :running do
        Enum.reduce(run.pending, state, fn {_approval_id, entry}, state ->
          subscriber = Map.fetch!(state.subscribers, subscriber.pid)
          enqueue(state, subscriber.pid, subscriber, {:approval_request, run_id, entry.request})
        end)
      else
        state
      end

    case run.status do
      {:done, outcome, output, model_requests} ->
        enqueue(state, subscriber.pid, Map.fetch!(state.subscribers, subscriber.pid), {
          :result,
          run_id,
          outcome,
          output,
          model_requests
        })

      :running ->
        state
    end
  end

  ## Run completion

  defp start_observed(task, opts) do
    with {:ok, handle} <- Runner.start(task, opts) do
      case Runner.subscribe(handle, self()) do
        {:ok, ref} ->
          {:ok, handle, ref}

        {:error, reason} ->
          Runner.terminate(handle, :subscription_failed)
          {:error, reason}
      end
    end
  end

  defp finish_run(state, run, run_result) do
    {outcome, output, model_requests} =
      case run_result do
        {:ok, result} ->
          {:ok, result.output, result.model_requests}

        {:error, {:cancelled, reason}, result} ->
          {{:cancelled, reason}, nil, model_requests_of(result)}

        {:error, reason, result} ->
          {{:error, reason}, nil, model_requests_of(result)}

        _other ->
          {{:error, :invalid_runner_result}, nil, 0}
      end

    # Cleanup: a finished run owns no pending approvals. Waiters that
    # outlive the run (crash mid-approval) are released here; cooperative
    # cancellation already cleared them via the waiter DOWN path.
    Enum.each(run.pending, fn {_approval_id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
    end)

    run = %{
      run
      | status: {:done, outcome, output, model_requests},
        result: run_result,
        pending: %{}
    }

    state = %{state | runs: Map.put(state.runs, run.id, run)}

    state = track_finished(state, run.id)

    publish(state, run.id, {:result, run.id, outcome, output, model_requests}, :result)
  end

  defp track_finished(state, run_id) do
    order = (Map.get(state, :finished_order, []) ++ [run_id]) |> Enum.uniq()
    limit = Map.get(state, :max_finished_runs, @default_max_finished_runs)
    overflow = max(length(order) - limit, 0)

    {evict, order} = Enum.split(order, overflow)

    runs =
      Enum.reduce(evict, state.runs, fn id, runs ->
        case Map.fetch(runs, id) do
          {:ok, %{status: {:done, _, _, _}}} -> Map.delete(runs, id)
          _other -> runs
        end
      end)

    subscribers =
      Map.new(state.subscribers, fn {pid, sub} ->
        {pid, %{sub | last_durable_seq: Map.drop(sub.last_durable_seq, evict)}}
      end)

    %{state | runs: runs, finished_order: order, subscribers: subscribers}
  end

  defp model_requests_of(nil), do: 0
  defp model_requests_of(%Alto.Runner.Result{} = result), do: result.model_requests

  ## Approvals

  defp resolve_approval(state, request_id, decision) do
    case find_pending(state, request_id: request_id) do
      nil ->
        {{:error, :not_found}, state}

      {run_id, request_id, entry} ->
        send(entry.waiter, {:alto_approval_decision, request_id, decision})
        Process.demonitor(entry.monitor, [:flush])

        state =
          update_run(state, run_id, fn run ->
            %{run | pending: Map.delete(run.pending, request_id)}
          end)

        {:ok, state}
    end
  end

  defp clear_pending(state, request_id: request_id) do
    case find_pending(state, request_id: request_id) do
      nil ->
        state

      {run_id, ^request_id, entry} ->
        Process.demonitor(entry.monitor, [:flush])

        update_run(state, run_id, fn run ->
          %{run | pending: Map.delete(run.pending, request_id)}
        end)
    end
  end

  defp clear_pending(state, monitor: monitor) do
    case find_pending(state, monitor: monitor) do
      nil ->
        state

      {run_id, request_id, _entry} ->
        update_run(state, run_id, fn run ->
          %{run | pending: Map.delete(run.pending, request_id)}
        end)
    end
  end

  ## Lookups and small helpers

  defp find_run(state, completion_ref: ref) do
    Enum.find_value(state.runs, fn {_id, run} -> if run.completion_ref == ref, do: run end)
  end

  defp find_subscriber(state, monitor: monitor) do
    Enum.find(state.subscribers, fn {_pid, subscriber} -> subscriber.monitor == monitor end)
  end

  defp find_pending(state, request_id: request_id) do
    Enum.find_value(state.runs, fn {run_id, run} ->
      case Map.fetch(run.pending, request_id) do
        {:ok, entry} -> {run_id, request_id, entry}
        :error -> nil
      end
    end)
  end

  defp find_pending(state, monitor: monitor) do
    Enum.find_value(state.runs, fn {run_id, run} ->
      Enum.find_value(run.pending, fn
        {request_id, %{monitor: ^monitor} = entry} -> {run_id, request_id, entry}
        _other -> nil
      end)
    end)
  end

  defp update_run(state, run_id, fun) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> %{state | runs: Map.put(state.runs, run_id, fun.(run))}
      :error -> state
    end
  end

  # : fresh served runs persist only when enabled (registry-owned session
  # identity, distinct from the run id); resume reuses the caller-named
  # session verbatim and carries the snapshot revision so concurrent writers
  # cannot silently replace one another. Unavailable storage never fails the
  # run — the serial result records degraded persistence.
  defp with_session(run_opts, session_opts, state) do
    run_opts
    |> Keyword.put(:session, Keyword.get(session_opts, :session))
    |> Keyword.put(:session_dir, state.session_dir)
    |> Keyword.merge(Keyword.delete(session_opts, :session))
  end

  # Reads the resumable transcript up front so an unrestorable session
  # fails the start instead of running with invented history. Mirrors
  # Alto.resume/3 over the registry's session directory.
  # Checkpoint packets are accepted only through this trusted Elixir API.
  # Socket start_run never accepts continuation state or approval decisions.
  defp execution_session_opts(opts, config_opts, state) do
    case Keyword.get(opts, :continuation) do
      nil ->
        checkpoint_session_opts(opts, state)

      identity ->
        with true <-
               is_nil(Keyword.get(opts, :checkpoint)) and is_nil(Keyword.get(opts, :resume)),
             {:ok, resolved} <-
               Alto.Runner.Execution.Parent.options(
                 Keyword.put(config_opts, :continuation, identity)
               ),
             session = Keyword.get(resolved, :session),
             :ok <- Alto.Session.validate_id(session) do
          {:ok, [session: session, continuation: identity]}
        else
          false -> {:error, :conflicting_continuation_options}
          {:error, _} = error -> error
        end
    end
  end

  defp checkpoint_session_opts(opts, state) do
    case Keyword.get(opts, :checkpoint) do
      nil ->
        resume_opts(Keyword.get(opts, :resume), state)

      {%{"session_id" => session} = packet, decision} when decision in [:approve, :deny] ->
        with :ok <- Alto.Session.validate_id(session) do
          {:ok, [session: session, checkpoint: {packet, decision}]}
        end

      _ ->
        {:error, :invalid_checkpoint}
    end
  end

  defp resume_opts(nil, state) do
    if state.sessions_enabled do
      {:ok, [session: Alto.Session.generate_id()]}
    else
      {:ok, []}
    end
  end

  defp resume_opts(session_id, state) when is_binary(session_id) do
    case Alto.Session.transcript(session_id, session_dir: state.session_dir) do
      {:ok, %{messages: messages, transcript_bytes: bytes, revision: revision}} ->
        {:ok,
         [
           session: session_id,
           resume: %{messages: messages, transcript_bytes: bytes, revision: revision}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_opts(other, _state), do: {:error, {:invalid_resume_option, other}}

  defp drop_subscriber(state, client_pid) do
    case Map.fetch(state.subscribers, client_pid) do
      {:ok, subscriber} ->
        Process.demonitor(subscriber.monitor, [:flush])
        %{state | subscribers: Map.delete(state.subscribers, client_pid)}

      :error ->
        state
    end
  end

  defp validate_task(task)
       when is_binary(task) and task != "" and byte_size(task) <= @max_task_bytes,
       do: :ok

  defp validate_task(_task), do: {:error, :invalid_task}

  defp resolve_config({module, function}, name) when is_atom(module) and is_atom(function),
    do: apply(module, function, [name])

  defp resolve_config(fun, name) when is_function(fun, 1), do: fun.(name)
end
