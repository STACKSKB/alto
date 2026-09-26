defmodule Alto.FrontEnd.Registry do
  @moduledoc """
  Resident hub for run lifetimes, bounded event replay, subscribers, and approvals.
  Transports encode its typed notifications through `Alto.Protocol`. Durable
  sequence numbers are provisional until the session store assigns final ones.
  Pull buffers report overflow explicitly; approval decisions ignore event
  filters, and the first decision wins.
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
    :input,
    :messaging,
    :session_id,
    :task_preview,
    :config_name,
    :started_at_ms,
    :start_order,
    events_rev: [],
    head_seq: 0,
    result: :running
  ]

  alias Alto.FrontEnd.Registry.Subscriber

  @options [
    max_buffer_messages: [type: :non_neg_integer, default: 10_000],
    max_buffer_bytes: [type: :non_neg_integer, default: 8_000_000],
    max_retained_events: [type: :non_neg_integer, default: 1_000],
    max_active_runs: [type: :non_neg_integer, default: 32],
    max_subscribers: [type: :non_neg_integer, default: 128],
    max_finished_runs: [type: :non_neg_integer, default: 100],
    max_claim_bytes: [type: :non_neg_integer, default: 1_046_528],
    command_timeout: [type: :pos_integer, default: 30_000],
    commands: [type: {:map, {:custom, __MODULE__, :command_name, []}, {:fun, 1}}, default: %{}],
    disconnect_after_overflow: [type: {:in, [:never, :immediately]}, default: :never]
  ]
  @options_schema NimbleOptions.new!(@options)
  @max_task_bytes 1_000_000

  ## Client API

  @doc """
  Start the registry. `:config_resolver` maps a configuration name to
  `{:ok, run_opts}` or `{:error, reason}`. `:queue` enables claim/ack;
  `:queue` and `:ledger` together enable read-only operation inspection.
  `:commands` maps trusted names to supervised callbacks; a timeout leaves an
  unknown outcome for the caller to reconcile.

  `:sessions` opts fresh served runs into persistence (`true` or
  `[session_dir: path]`). Resume can read `:session_dir` regardless of that
  setting. `:cwd` defaults to the process directory and `:name` to this module.
  The buffer, replay, claim-size, command-timeout, and overflow
  controls and their defaults are declared in `@options`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Start a run from a trusted configuration name. `:resume` requires a completed
  transcript snapshot; a crashed run cannot be replayed as new work. Trusted
  callers may set `:owner`, `:cwd`, or validated `:reasoning_effort`; wire
  clients cannot override the provider, tools, approval, or workspace.
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
      case Alto.Runner.Execution.Call.run(
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

  @doc "Queue user input for a resident run or one of its agents."
  def send_message(server, run_id, opts),
    do: GenServer.call(server, {:send_message, run_id, opts})

  def list_agents(server, run_id), do: GenServer.call(server, {:list_agents, run_id})

  @doc "Inspect pending root messages, including after completion."
  def input_status(server, run_id), do: GenServer.call(server, {:input_status, run_id})

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
  the pull/ack half of the job flow.

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

    with {:ok, options} <-
           NimbleOptions.validate(Keyword.take(opts, Keyword.keys(@options)), @options_schema) do
      state =
        Map.merge(Map.new(options), %{
          resolver: Keyword.fetch!(opts, :config_resolver),
          cwd: Keyword.get(opts, :cwd, File.cwd!()),
          queue: Keyword.get(opts, :queue),
          ledger: Keyword.get(opts, :ledger),
          sessions_enabled: sessions_enabled,
          session_dir: session_dir,
          subscribers: %{},
          pending: %{},
          runs: %{},
          finished_order: []
        })

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

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

  defp validate_owner(owner) when is_pid(owner), do: :ok
  defp validate_owner(owner), do: {:error, {:invalid_owner, owner}}

  @doc false
  def command_name(name) when is_binary(name) and name != "", do: {:ok, name}
  def command_name(_name), do: {:error, "expected a nonempty command name"}

  defp active_capacity(state) do
    count = Enum.count(state.runs, fn {_id, run} -> run.result == :running end)
    if count < state.max_active_runs, do: :ok, else: {:error, :run_capacity}
  end

  @impl true
  def handle_call({:start_run, config_name, task, opts}, _from, state) do
    owner = Keyword.get(opts, :owner, self())
    run_id = "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- validate_owner(owner),
         :ok <- active_capacity(state),
         :ok <- validate_task(task),
         {:ok, config_opts} <- resolve_config(state.resolver, config_name),
         {:ok, session_opts} <- execution_session_opts(opts, config_opts, state),
         {:ok, input} <- Alto.Input.open(transport: config_opts[:messaging_transport], id: run_id) do
      me = self()

      {:ok, messaging} =
        Alto.Messaging.start_link(owner: self(), transport: config_opts[:messaging_transport])

      run_opts =
        config_opts
        |> Keyword.merge(Keyword.take(opts, [:budget_account, :cwd]))
        |> Alto.Reasoning.configure_run(Keyword.get(opts, :reasoning_effort))
        |> Keyword.put_new(:cwd, state.cwd)
        |> Keyword.put_new(:project_instructions, :auto)
        |> Keyword.put(:session_id, run_id)
        |> Keyword.put(:input, input)
        |> Keyword.put(:messaging, messaging)
        |> Keyword.put(:owner, owner)
        |> Keyword.put(:tool_context_metadata, %{front_end_registry: me})
        |> Alto.Events.attach(fn event ->
          GenServer.call(me, {:ingest_run_event, run_id, event})
        end)
        |> with_session(session_opts, state)

      case start_observed(task, run_opts) do
        {:ok, handle, completion_ref} ->
          run = %__MODULE__{
            id: run_id,
            handle: handle,
            completion_ref: completion_ref,
            input: input,
            messaging: messaging,
            session_id: Keyword.get(session_opts, :session),
            task_preview: String.slice(task, 0, 120),
            config_name: config_name,
            started_at_ms: System.system_time(:millisecond),
            start_order: System.unique_integer([:positive, :monotonic])
          }

          {:reply, {:ok, run_id}, %{state | runs: Map.put(state.runs, run_id, run)}}

        {:error, reason} ->
          GenServer.stop(messaging)
          Alto.Input.close(input)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:run_result, run_id}, _from, state) do
    reply_with_run(state, run_id, fn
      %{result: :running} -> :running
      %{result: result} -> {:ok, result}
    end)
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
      |> Enum.map(&run_summary(&1, state.pending))

    {:reply, {:ok, summaries}, state}
  end

  def handle_call(:run_ids, _from, state) do
    live = for {id, %{result: :running}} <- state.runs, do: id
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
          monitor: Process.monitor(client_pid),
          run_id: run_id,
          domains: MapSet.new(domains),
          max_buffer_messages: state.max_buffer_messages,
          max_buffer_bytes: state.max_buffer_bytes
        }

        state = %{state | subscribers: Map.put(state.subscribers, client_pid, subscriber)}
        state = deliver_attach(state, client_pid, run_id, from_seq)

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

  def handle_call({:send_message, run_id, opts}, _from, state) do
    reply_with_run(state, run_id, fn run ->
      {to, opts} = Keyword.pop(opts, :to)

      cond do
        to -> Alto.Messaging.send(run.messaging, to, opts)
        run.result == :running -> Alto.Messaging.send(run.input, opts)
        true -> Alto.Messaging.duplicate(run.input, opts)
      end
    end)
  end

  def handle_call({:list_agents, run_id}, _from, state) do
    reply_with_run(state, run_id, fn run ->
      with {:ok, agents} <- Alto.Messaging.list(run.messaging), do: {:ok, %{agents: agents}}
    end)
  end

  def handle_call({:input_status, run_id}, _from, state) do
    reply_with_run(state, run_id, &{:ok, Alto.Input.list(&1.input)})
  end

  def handle_call({:cancel, run_id, reason}, _from, state) do
    reply_with_run(state, run_id, fn run ->
      Runner.cancel(run.handle, reason)
      :ok
    end)
  end

  # Approval handles are globally unique operation ids: no scoping
  # or random-suffix patch. The handle in `request.id` is the
  # key; `call_id` is correlation only. A duplicate handle is a caller bug
  # and is rejected instead of silently replacing the waiter.
  def handle_call({:request_approval, session_id, request, waiter}, _from, state)
      when is_binary(request.id) do
    case Map.fetch(state.runs, session_id) do
      :error ->
        {:reply, {:error, :unknown_run}, state}

      {:ok, run} ->
        if Map.has_key?(state.pending, request.id) do
          {:reply, {:error, :already_pending}, state}
        else
          entry = %{
            run_id: run.id,
            waiter: waiter,
            monitor: Process.monitor(waiter),
            request: request
          }

          state = put_in(state.pending[request.id], entry)

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

  defp reply_with_run(state, run_id, fun) do
    reply =
      case state.runs[run_id] do
        nil -> {:error, :unknown_run}
        run -> fun.(run)
      end

    {:reply, reply, state}
  end

  # A dead or crashing queue must not take the registry — and every
  # unrelated run it owns — down with it. Queue failures stay observable
  # per call.
  defp queue_op(%{queue: nil}, _fun), do: {:error, :no_queue}
  defp queue_op(_state, fun), do: guarded_store_call(fun, :queue_unavailable)

  # A dead store fails this inspection call without taking down the registry.
  defp ops_list_op(%{queue: nil}, _opts), do: {:error, :no_ops}
  defp ops_list_op(%{ledger: nil}, _opts), do: {:error, :no_ops}

  defp ops_list_op(%{queue: queue, ledger: ledger}, opts),
    do: guarded_store_call(fn -> Alto.Ops.list(queue, ledger, opts) end, :ops_unavailable)

  defp guarded_store_call(fun, unavailable) do
    fun.()
  rescue
    error -> {:error, {unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {unavailable, reason}}
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
  def handle_info({:alto_runner_result, ref, outcome}, state) do
    case find_run(state, completion_ref: ref) do
      %{result: :running} = run -> {:noreply, finish_run(state, run, outcome)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    request_id =
      Enum.find_value(state.pending, fn {id, entry} -> if entry.monitor == monitor, do: id end)

    {:noreply, state |> maybe_drop_subscriber(monitor) |> clear_pending(request_id)}
  end

  defp maybe_drop_subscriber(state, monitor) do
    case Enum.find(state.subscribers, fn {_pid, subscriber} -> subscriber.monitor == monitor end) do
      {pid, _subscriber} -> drop_subscriber(state, pid)
      nil -> state
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.subscribers, fn {pid, _subscriber} -> send(pid, :alto_close) end)
    Enum.each(state.runs, fn {_, run} -> close_channels(run) end)
    :ok
  end

  defp run_summary(run, pending) do
    status =
      case run.result do
        :running -> "running"
        {:error, :approval_suspended, _} -> "suspended"
        {:ok, _} -> "completed"
        {:error, {:cancelled, _}, _} -> "cancelled"
        _ -> "failed"
      end

    usage =
      case run.result do
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
      pending_approvals: Enum.count(pending, fn {_, entry} -> entry.run_id == run.id end),
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
        events_rev: Enum.take([{seq, event} | run.events_rev], state.max_retained_events)
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
          |> clear_pending(request.id)
          |> publish(run.id, {:approval_resolved, run.id, request, decision}, :approval)

        _other ->
          state
      end

    publish(state, run.id, {:event, run.id, nil, event}, :live)
  end

  ## Fanout

  # `:durable`/`:live` honor the subscriber's domain filter; approvals and
  # results always reach every client attached to the run.
  defp publish(state, run_id, notification, domain) do
    Enum.reduce(state.subscribers, state, fn {pid, subscriber}, state ->
      if Subscriber.interested?(subscriber, run_id, domain) do
        enqueue(state, pid, notification)
      else
        state
      end
    end)
  end

  defp enqueue(state, pid, notification) do
    update_in(state.subscribers[pid], &Subscriber.enqueue(&1, notification))
  end

  defp deliver_pull(state, client_pid, subscriber, count) do
    {subscriber, messages} = Subscriber.pull(subscriber, count, state.disconnect_after_overflow)
    Enum.each(messages, &send(client_pid, &1))
    put_in(state.subscribers[client_pid], subscriber)
  end

  ## Attach and replay

  # A wildcard attach subscribes to all present and future runs: replay every
  # running run's pending approvals so a reconnecting client can still answer.
  defp deliver_attach(state, pid, nil, _from_seq), do: replay_approvals(state, pid, nil)

  defp deliver_attach(state, pid, run_id, from_seq) do
    run = Map.fetch!(state.runs, run_id)
    dropped = run.head_seq - length(run.events_rev)
    gap = from_seq <= dropped and dropped > 0

    replay =
      run.events_rev
      |> Enum.reverse()
      |> Enum.filter(fn {seq, _event} -> seq >= from_seq end)

    state = enqueue(state, pid, {:attached, run_id, gap, run.head_seq, replay})

    # Pending approvals are live-only; replay them after the durable envelope.
    state = replay_approvals(state, pid, run_id)

    if run.result == :running do
      state
    else
      enqueue(state, pid, result_notification(run))
    end
  end

  defp replay_approvals(state, pid, run_id) do
    Enum.reduce(state.pending, state, fn {_id, entry}, state ->
      if is_nil(run_id) or entry.run_id == run_id,
        do: enqueue(state, pid, {:approval_request, entry.run_id, entry.request}),
        else: state
    end)
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
    # Cleanup: a finished run owns no pending approvals. Waiters that
    # outlive the run (crash mid-approval) are released here; cooperative
    # cancellation already cleared them via the waiter DOWN path.
    state =
      Enum.reduce(state.pending, state, fn {id, entry}, state ->
        if entry.run_id == run.id, do: clear_pending(state, id), else: state
      end)

    run = %{run | result: run_result}
    state = put_in(state.runs[run.id], run)

    state = track_finished(state, run.id)

    publish(state, run.id, result_notification(run), :result)
  end

  defp result_notification(run) do
    {outcome, output, model_requests} =
      case run.result do
        {:ok, result} ->
          {:ok, result.output, result.model_requests}

        {:error, {:cancelled, reason}, result} ->
          {{:cancelled, reason}, nil, model_requests_of(result)}

        {:error, reason, result} ->
          {{:error, reason}, nil, model_requests_of(result)}

        _other ->
          {{:error, :invalid_runner_result}, nil, 0}
      end

    {:result, run.id, outcome, output, model_requests}
  end

  defp track_finished(state, run_id) do
    order = state.finished_order ++ [run_id]
    limit = state.max_finished_runs
    overflow = max(length(order) - limit, 0)

    {evict, order} = Enum.split(order, overflow)
    Enum.each(evict, &close_channels(state.runs[&1]))

    subscribers =
      Map.new(state.subscribers, fn {pid, sub} ->
        {pid, %{sub | last_durable_seq: Map.drop(sub.last_durable_seq, evict)}}
      end)

    %{state | runs: Map.drop(state.runs, evict), finished_order: order, subscribers: subscribers}
  end

  defp close_channels(run) do
    if Process.alive?(run.messaging), do: GenServer.stop(run.messaging)
    Alto.Input.close(run.input)
  end

  defp model_requests_of(nil), do: 0
  defp model_requests_of(%Alto.Runner.Result{} = result), do: result.model_requests

  ## Approvals

  defp resolve_approval(state, request_id, decision) do
    case take_pending(state, request_id) do
      {nil, state} ->
        {{:error, :not_found}, state}

      {entry, state} ->
        send(entry.waiter, {:alto_approval_decision, request_id, decision})
        {:ok, state}
    end
  end

  defp clear_pending(state, request_id), do: elem(take_pending(state, request_id), 1)

  defp take_pending(state, request_id) do
    {entry, pending} = Map.pop(state.pending, request_id)
    if entry, do: Process.demonitor(entry.monitor, [:flush])
    {entry, %{state | pending: pending}}
  end

  ## Lookups and small helpers

  defp find_run(state, completion_ref: ref) do
    Enum.find_value(state.runs, fn {_id, run} -> if run.completion_ref == ref, do: run end)
  end

  # Resume carries the snapshot revision so concurrent writers cannot silently
  # replace one another. Storage failure degrades the result without failing the run.
  defp with_session(run_opts, session_opts, state) do
    run_opts
    |> Keyword.put(:session, Keyword.get(session_opts, :session))
    |> Keyword.put(:session_dir, state.session_dir)
    |> Keyword.merge(Keyword.delete(session_opts, :session))
  end

  # Reads the resumable transcript up front so an unrestorable session
  # fails the start instead of running with invented history.
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

  defp resume_opts(session_id, state) when is_binary(session_id),
    do: Alto.Session.resume_options(session_id, session_dir: state.session_dir)

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
