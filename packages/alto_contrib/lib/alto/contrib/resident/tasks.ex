defmodule Alto.Contrib.Resident.Tasks do
  @moduledoc """
  Resident task policy composed from Alto's durable queue, consumers and ledger.

  This process keeps only live run associations. Task admission, due times,
  dispatch attempts, outcomes and operator decisions belong to Alto stores.
  An interrupted attempt is parked before any recovered work is allowed to run.
  """
  use GenServer
  alias Alto.{OperationLog, Queue}
  alias Alto.Contrib.FrontEnd.Registry, as: Runs
  alias Alto.Contrib.Resident.Service

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Service.component(name, :tasks))
  end

  def command(name, operation, payload),
    do: GenServer.call(Service.component(name, :tasks), {operation, payload}, 10_000)

  def commands(name) do
    Map.new(
      ~w(submit list get cancel reconcile decide recover child_decide cleanup),
      fn operation ->
        {"tasks." <> operation, fn payload -> command(name, operation, payload) end}
      end
    )
    |> Map.put("tasks.efforts", fn payload ->
      config = GenServer.call(Service.component(name, :tasks), :configuration)

      with {:ok, info} <- Alto.Contrib.Resident.Effort.catalog(config, payload["profile"]) do
        GenServer.call(
          Service.component(name, :tasks),
          {:effort_catalog, payload["profile"], info}
        )

        {:ok, info}
      end
    end)
  end

  def children(config, name) do
    queue = Service.component(name, :queue)
    ledger = Service.component(name, :ledger)
    settings = config.scheduling

    stores = [
      {Queue,
       name: queue,
       id: "tasks",
       dir: Path.join(config.state_dir, "queues"),
       max_records: settings[:max_pending],
       max_completed: settings[:max_tasks],
       lease_ms: settings[:run_timeout] + 30_000},
      {OperationLog,
       name: ledger,
       id: "tasks",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: settings[:max_tasks],
       max_recovery_bytes: 2_000_000,
       max_record_bytes: 4_000_000}
    ]

    workers =
      for index <- 1..settings[:workers] do
        Supervisor.child_spec(
          {Alto.Consumer,
           name: Service.component(name, {:worker, index}),
           queue: queue,
           ledger: ledger,
           by: "alto_resident-#{index}",
           tool: "alto_resident_task",
           batch: 1,
           max_attempts: settings[:max_attempts],
           poll_ms: settings[:poll_ms],
           handle_timeout: settings[:run_timeout] + 5_000,
           handler: fn payload, context -> execute(name, payload, context) end},
          id: {:worker, index}
        )
      end

    {stores, [{__MODULE__, name: name, config: config}] ++ workers}
  end

  def resolve(config, "scheduled/" <> profile) do
    with {:ok, options} <- Alto.Contrib.Resident.Config.resolve(config, profile) do
      bounded =
        Enum.reduce([:run_timeout, :max_model_requests, :max_effects], options, fn key, acc ->
          Keyword.put(
            acc,
            key,
            min(Keyword.get(acc, key, config.scheduling[key]), config.scheduling[key])
          )
        end)

      {:ok, bounded}
    end
  end

  def resolve(config, profile), do: Alto.Contrib.Resident.Config.resolve(config, profile)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    state = %{
      name: name,
      config: Keyword.fetch!(opts, :config),
      queue: Service.component(name, :queue),
      ledger: Service.component(name, :ledger),
      active: %{},
      effort_catalog: %{},
      pending_admissions: MapSet.new()
    }

    case reconcile_restart(state) do
      :ok ->
        queued = MapSet.new(queue_records(state.queue), &operation_key/1)

        pending =
          for %{operation_key: id, status: {:intended}} <-
                OperationLog.request(state.ledger, {:entries, :all}),
              not MapSet.member?(queued, id),
              into: MapSet.new(),
              do: id

        schedule_admissions()
        {:ok, %{state | pending_admissions: pending}}

      {:error, reason} ->
        {:stop, {:task_recovery_failed, reason}}
    end
  end

  @impl true
  def handle_call({"submit", payload}, _from, state) do
    reply =
      with {:ok, task} <- validate_submission(payload, state.config, state.effort_catalog),
           :no_intent <- OperationLog.request(state.ledger, {:status, task["id"]}),
           :ok <- Alto.Contrib.Resident.Lifecycle.available?(state.config, state.name, task),
           {:ok, _} <-
             Queue.request(
               state.queue,
               {:admit, task["id"], task, [not_before_ms: task["not_before_ms"]]}
             ) do
        {:ok, %{"task_id" => task["id"], "status" => "queued"}}
      else
        {:error, :duplicate} -> {:ok, %{"task_id" => payload["id"], "duplicate" => true}}
        {:error, {:key_claimed, key}} -> {:ok, %{"task_id" => key, "duplicate" => true}}
        {:error, _} = error -> error
        _ -> {:ok, %{"task_id" => payload["id"], "duplicate" => true}}
      end

    {:reply, reply, state}
  end

  def handle_call({"list", payload}, _from, state) do
    session_ids = Map.get(payload, "session_ids", [])
    ids = Map.get(payload, "ids", [])

    if valid_selection?(session_ids) and valid_selection?(ids) do
      {:reply, {:ok, list_tasks(state, session_ids, ids)}, state}
    else
      {:reply, {:error, :invalid_task_selection}, state}
    end
  end

  def handle_call({"get", %{"id" => id}}, _from, state) when is_binary(id) do
    record =
      case find_record(state, id) do
        {:ok, r} -> r
        _ -> nil
      end

    recovery =
      case OperationLog.request(state.ledger, {:recovery, id}) do
        {:ok, r} -> r
        _ -> nil
      end

    reply =
      case describe(state, id, record, recovery, true) do
        nil -> {:error, :unknown_task}
        task -> {:ok, %{"task" => task}}
      end

    {:reply, reply, state}
  end

  def handle_call({"cancel", %{"id" => id}}, _from, state) when is_binary(id) do
    reply = cancel_task(state, id)
    {:reply, reply, state}
  end

  def handle_call({"recover", %{"id" => id, "revision" => revision} = payload}, from, state)
      when is_binary(id) and is_integer(revision) do
    with :ok <- may_reconcile(state, id),
         {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}),
         true <- recovered.revision == revision,
         profile = get_in(recovered.recovery, [:payload, "profile"]),
         :ok <-
           Alto.Contrib.Resident.ParentRuns.recoverable(
             state.config,
             profile,
             id,
             payload,
             get_in(recovered.recovery, [:payload, "parent_store"]),
             state.name
           ) do
      handle_call(
        {"reconcile",
         %{
           "id" => id,
           "revision" => revision,
           "resolution" => "retry",
           "note" => "Resume exact retained parent continuation",
           :parent_recovery => true
         }},
        from,
        state
      )
    else
      false -> {:reply, {:error, :stale_revision}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({"cleanup", %{"id" => id, "revision" => revision}}, _from, state)
      when is_binary(id) and is_integer(revision) and revision > 0 do
    reply =
      with nil <- state.active[id],
           {:error, :not_found} <- find_record(state, id),
           {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}),
           true <- recovered.revision == revision,
           {:decided, class, _} when class not in [:unknown, :requires_operator] <-
             recovered.status do
        Alto.Contrib.Resident.Lifecycle.cleanup(state.config, state.name, recovered)
      else
        false ->
          {:error, :stale_revision}

        {:error, :not_found} ->
          Alto.Contrib.Resident.Lifecycle.resume(state.config, state.name, id, revision)

        {:error, _} = error ->
          error

        _ ->
          {:error, :task_not_terminal}
      end

    {:reply, reply, state}
  end

  def handle_call({"child_decide", %{"id" => id, "revision" => revision} = request}, from, state)
      when is_binary(id) and is_integer(revision) and revision > 0 do
    with :ok <- may_reconcile(state, id),
         {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}),
         true <- recovered.revision == revision,
         {:ok, parent_request} <-
           Alto.Contrib.Resident.ParentRuns.decide_child(
             state.config,
             recovered.recovery[:payload],
             request,
             state.name
           ) do
      # The exact decision is durable even if queue admission subsequently fails.
      # task-recover can then readmit it; it cannot approve a different suspension.
      handle_call(
        {"recover", Map.merge(parent_request, %{"id" => id, "revision" => revision})},
        from,
        state
      )
    else
      false -> {:reply, {:error, :stale_revision}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {"reconcile",
         %{"id" => id, "revision" => revision, "resolution" => resolution} = payload},
        _from,
        state
      )
      when is_binary(id) and is_integer(revision) do
    resolution =
      %{
        "committed" => :confirmed_committed,
        "failed" => :confirmed_failed,
        "retry" => :retry_permitted
      }[resolution]

    note = Map.get(payload, "note")
    evidence = %{"note" => note}

    reply =
      with true <- not is_nil(resolution) and is_binary(note) and byte_size(note) in 1..4_096,
           :ok <- may_reconcile(state, id),
           :ok <- parent_retry_check(state, id, resolution, payload),
           {:ok, recovered} <-
             OperationLog.request(state.ledger, {:reconcile, id, revision, resolution, evidence}),
           admission when admission in [:ok, {:error, :queue_full}] <-
             restore_if_retry(state, id, resolution, recovered) do
        {:accepted, recovered.revision, admission}
      else
        false -> {:error, :invalid_resolution}
        {:error, _} = error -> error
      end

    case reply do
      {:accepted, revision, {:error, :queue_full}} ->
        pending = MapSet.put(state.pending_admissions, id)

        {:reply,
         {:ok, %{"task_id" => id, "revision" => revision, "status" => "awaiting_admission"}},
         %{state | pending_admissions: pending}}

      {:accepted, revision, :ok} ->
        {:reply, {:ok, %{"task_id" => id, "revision" => revision}}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {"decide", %{"id" => id, "revision" => revision, "decision" => decision}},
        _from,
        state
      )
      when is_binary(id) and is_integer(revision) and decision in ["approve", "deny"] do
    reply =
      with {:ok, current} <- OperationLog.request(state.ledger, {:recovery, id}),
           :ok <-
             checkpoint_upgrade_check(
               current.checkpoint,
               state.config,
               get_in(current.recovery, [:payload, "profile"])
             ),
           {:ok, recovered} <-
             OperationLog.request(
               state.ledger,
               {:resume_checkpoint, id, revision, %{"decision" => decision}}
             ),
           admission when admission in [:ok, {:error, :queue_full}] <-
             restore_if_retry(state, id, :retry_permitted, recovered) do
        {:accepted, recovered.revision, admission}
      else
        {:error, _} = error -> error
        _ -> {:error, :task_still_running}
      end

    case reply do
      {:accepted, revision, admission} ->
        pending =
          if admission == {:error, :queue_full},
            do: MapSet.put(state.pending_admissions, id),
            else: state.pending_admissions

        {:reply, {:ok, %{"task_id" => id, "revision" => revision}},
         %{state | pending_admissions: pending}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:started, id, run_id, session_id, worker}, _from, state) do
    ref = Process.monitor(worker)
    active = Map.put(state.active, id, %{run_id: run_id, session_id: session_id, monitor: ref})

    reply =
      with {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}) do
        if get_in(recovered.recovery, [:payload, "parent_store"]),
          do: Alto.Contrib.Resident.ParentRuns.record_run(state.name, id, run_id),
          else: :ok
      end

    {:reply, reply, %{state | active: active}}
  end

  def handle_call({:effort_catalog, profile, info}, _from, state),
    do: {:reply, :ok, %{state | effort_catalog: Map.put(state.effort_catalog, profile, info)}}

  def handle_call(:configuration, _from, state), do: {:reply, state.config, state}
  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_task_command}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do:
      {:noreply,
       %{state | active: Map.reject(state.active, fn {_, run} -> run.monitor == ref end)}}

  def handle_info(:repair_admissions, state) do
    pending =
      Enum.reduce(state.pending_admissions, MapSet.new(), fn id, waiting ->
        result =
          if OperationLog.request(state.ledger, {:status, id}) == {:intended},
            do: repair_admission(state, id),
            else: :ok

        case result do
          :ok -> waiting
          {:error, :queue_full} -> MapSet.put(waiting, id)
          {:error, reason} -> exit({:task_admission_failed, id, reason})
        end
      end)

    schedule_admissions()
    {:noreply, %{state | pending_admissions: pending}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule_admissions, do: Process.send_after(self(), :repair_admissions, 250)

  defp validate_submission(%{"profile" => profile, "task" => text} = payload, config, catalogs)
       when is_binary(profile) and is_binary(text) and byte_size(text) in 1..32_000 do
    id =
      Map.get(
        payload,
        "id",
        "task-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    delay = Map.get(payload, "delay_ms", 0)
    resume = Map.get(payload, "resume")
    now = System.system_time(:millisecond)

    with true <- is_binary(id) and String.match?(id, ~r/\A[A-Za-z0-9_-]{1,100}\z/),
         true <- is_integer(delay) and delay in 0..31_536_000_000,
         true <- is_nil(resume) or is_binary(resume),
         {:ok, options} <- Alto.Contrib.Resident.Config.resolve(config, profile),
         :ok <- validate_effort(payload["reasoning_effort"], options, Map.get(catalogs, profile)),
         {:ok, root} <-
           Alto.Contrib.Resident.Projects.root(
             config,
             payload["workspace_id"],
             Keyword.get(options, :cwd, config.workspace)
           ),
         {:ok, root} <-
           Alto.Contrib.Resident.Projects.resume_root(
             config,
             resume,
             root,
             not is_nil(payload["workspace_id"])
           ),
         {:ok, parent_store} <- Alto.Contrib.Resident.ParentRuns.store_binding(options),
         {:ok, project} <- Alto.Contrib.Resident.Projects.bind(config, root) do
      {:ok,
       %{
         "id" => id,
         "profile" => profile,
         "reasoning_effort" => payload["reasoning_effort"],
         "reasoning_model" => Alto.Contrib.Resident.Effort.model(options),
         "parent_store" => parent_store,
         "workspace_id" => project["id"],
         "cwd" => project["root"],
         "task" => text,
         "resume" => resume,
         "created_at_ms" => now,
         "not_before_ms" => now + delay
       }}
    else
      false -> {:error, :invalid_task}
      {:error, _} = error -> error
    end
  end

  defp validate_submission(_, _, _), do: {:error, :invalid_task}

  defp validate_effort(nil, _options, _catalog), do: :ok

  defp validate_effort(effort, options, %{model: model, efforts: choices}) do
    if model == Alto.Contrib.Resident.Effort.model(options) and effort in choices,
      do: :ok,
      else: {:error, :unsupported_reasoning_effort}
  end

  defp validate_effort(_, _, _), do: {:error, :refresh_effort_catalog}

  defp execute(name, payload, context) do
    registry = Service.registry(name)

    outcome =
      with {:ok, opts} <- execution_options(name, payload, context),
           do:
             Runs.request(
               registry,
               {:start_run, "scheduled/" <> payload["profile"], payload["task"], opts}
             )

    case outcome do
      {:ok, run} ->
        session = Runs.request(registry, {:run_session, run})

        case GenServer.call(
               Service.component(name, :tasks),
               {:started, context.operation_key, run, session, self()}
             ) do
          :ok ->
            :ok = Runs.request(registry, {:attach, self(), run, 1, []})
            await_run(registry, run, session)

          {:error, reason} ->
            Runs.request(registry, {:cancel, run, :parent_binding_unavailable})
            parked(:parent_binding_unavailable, reason, run, session)
        end

      {:error, reason} ->
        if payload["parent_store"],
          do: parked(:parent_recovery_unavailable, reason),
          else: {:outcome, :rejected_before_dispatch, %{reason: inspect(reason)}}
    end
  end

  defp execution_options(name, payload, context) do
    {:ok, recovered} =
      OperationLog.request(Service.component(name, :ledger), {:recovery, context.operation_key})

    grant = Map.get(recovered, :checkpoint_grant_revision)
    decision = get_in(recovered, [:checkpoint_decision, "decision"])
    config = GenServer.call(Service.component(name, :tasks), :configuration)

    approval_resume? =
      is_integer(grant) and recovered.revision == grant + 1 and decision in ["approve", "deny"]

    with {:ok, profile_options} <- resolve(config, "scheduled/" <> payload["profile"]),
         :ok <- effort_model_matches(payload, profile_options),
         {:ok, extra} <-
           Alto.Contrib.Resident.ParentRuns.options(
             profile_options,
             name,
             payload,
             approval_resume?
           ) do
      opts = [owner: self()] ++ extra

      opts =
        if payload["reasoning_effort"],
          do: Keyword.put(opts, :reasoning_effort, payload["reasoning_effort"]),
          else: opts

      opts = if payload["cwd"], do: Keyword.put(opts, :cwd, payload["cwd"]), else: opts

      opts =
        cond do
          approval_resume? ->
            decision = if decision == "approve", do: :approve, else: :deny
            Keyword.put(opts, :checkpoint, {recovered.checkpoint, decision})

          is_binary(payload["resume"]) and not Keyword.has_key?(opts, :continuation) ->
            Keyword.put(opts, :resume, payload["resume"])

          true ->
            opts
        end

      {:ok, opts}
    end
  end

  defp effort_model_matches(%{"reasoning_effort" => effort} = payload, options)
       when is_binary(effort) do
    if payload["reasoning_model"] == Alto.Contrib.Resident.Effort.model(options),
      do: :ok,
      else: {:error, :reasoning_model_changed}
  end

  defp effort_model_matches(_, _), do: :ok

  defp await_run(registry, run, session) do
    case Runs.request(registry, {:run_result, run}) do
      :running ->
        Runs.pull(registry, self(), 100)

        receive do
          {:alto_notification, {:result, ^run, _}} -> await_run(registry, run, session)
          {:alto_notification, _} -> await_run(registry, run, session)
        after
          100 -> await_run(registry, run, session)
        end

      {:ok, result} ->
        Runs.request(registry, {:detach, self()})
        task_outcome(result, run, session)

      {:error, reason} ->
        parked(:result_unavailable, reason, run, session)
    end
  end

  defp task_outcome(
         %Alto.Runner.Result{reason: :approval_suspended, checkpoint: packet},
         _run,
         _session
       )
       when is_map(packet),
       do: {:checkpoint, packet}

  defp task_outcome(
         %Alto.Runner.Result{status: :cancelled, checkpoint: %{"kind" => "parent"}} = value,
         run,
         session
       ),
       do: task_outcome(%{value | checkpoint: nil}, run, session)

  defp task_outcome(
         %Alto.Runner.Result{checkpoint: %{"kind" => "parent"}, reason: reason},
         run,
         session
       ),
       do: parked(:parent_continuation, reason, run, session)

  defp task_outcome(%Alto.Runner.Result{} = value, run, session) do
    status =
      case value.status do
        :ok -> "completed"
        :cancelled -> "cancelled"
        _ -> "failed"
      end

    reason =
      if value.reason,
        do: value.reason |> inspect(limit: 10, printable_limit: 2_048) |> String.slice(0, 2_048)

    class =
      case {status, value.verdict} do
        {"completed", :empty} -> :completed
        {_, :empty} -> :rejected_before_dispatch
        {_, verdict} -> verdict
      end

    evidence = %{
      run_id: run,
      session_id: session,
      status: status,
      usage: value.usage,
      agent_identity: Map.get(value, :agent_identity),
      persistence: value.persistence
    }

    evidence = if is_nil(reason), do: evidence, else: Map.put(evidence, :reason, reason)
    {:outcome, class, evidence}
  end

  defp task_outcome(result, run, session),
    do: parked(:runner_failed_without_result, result, run, session)

  defp parked(reason, detail, run \\ nil, session \\ nil) do
    {:outcome, :requires_operator,
     %{
       park_reason: reason,
       reason: detail |> inspect(limit: 10, printable_limit: 2_048) |> String.slice(0, 2_048),
       run_id: run,
       session_id: session
     }}
  end

  defp describe(state, id, record, recovery, include_parent \\ false) do
    payload = (record && record.payload) || (recovery && get_in(recovery, [:recovery, :payload]))

    if payload do
      active = state.active[id]
      checkpoint = if recovery, do: Map.get(recovery, :checkpoint) || %{}, else: %{}
      checkpoint_details = checkpoint_details(checkpoint)
      # Status, evidence and revision must describe one ledger snapshot. A second
      # status read can observe completion with the previous dispatch revision.
      ledger_status = if recovery, do: recovery.status, else: nil
      status = task_status(ledger_status, record, active)

      evidence =
        case ledger_status do
          {:decided, _, ev} -> ev
          _ -> %{}
        end

      %{
        "id" => id,
        "profile" => payload["profile"],
        "reasoning_effort" => payload["reasoning_effort"],
        "workspace_id" => payload["workspace_id"],
        "cwd" => payload["cwd"] || state.config.workspace,
        "task" => payload["task"],
        "status" => status,
        "parent_continuation" =>
          if(include_parent and status == "requires_operator",
            do:
              Alto.Contrib.Resident.ParentRuns.inspect_task(
                state.config,
                payload["profile"],
                id,
                payload["parent_store"],
                state.name
              )
          ),
        "created_at_ms" => payload["created_at_ms"],
        "not_before_ms" => payload["not_before_ms"],
        "run_id" => (active && active.run_id) || (evidence[:run_id] || evidence["run_id"]),
        "approval" => if(status == "waiting_approval", do: checkpoint["request"], else: nil),
        "upgrade_required" =>
          if(
            status == "waiting_approval" and
              legacy_checkpoint?(checkpoint, state.config, payload["profile"]),
            do: "pre_refactor_checkpoint",
            else: nil
          ),
        "agent_identity" =>
          Alto.Contrib.Protocol.encode_term(
            evidence[:agent_identity] || evidence["agent_identity"] ||
              checkpoint_details[:agent_identity] || checkpoint["agent_identity"]
          ),
        "usage" =>
          Alto.Contrib.Protocol.encode_term(
            evidence[:usage] || evidence["usage"] || checkpoint_details[:usage] ||
              checkpoint["usage"] || %{}
          ),
        "session_id" =>
          (active && active.session_id) || (evidence[:session_id] || evidence["session_id"]) ||
            checkpoint["session_id"],
        "revision" => recovery && recovery.revision,
        "evidence" => Alto.Contrib.Protocol.encode_term(evidence)
      }
    end
  end

  defp checkpoint_details(%{"continuation_format" => 4, "state" => encoded}) do
    case Alto.Runner.Checkpoint.decode(encoded) do
      {:ok, %{run: run}} when is_map(run) -> Map.take(run, [:usage, :agent_identity])
      _ -> %{}
    end
  end

  defp checkpoint_details(_), do: %{}

  # Alto changed the serialized execution state as well as the packet envelope.
  # Other runners retain control over their own compatibility checks below.
  defp legacy_checkpoint?(%{"format" => 1, "state" => state} = packet)
       when is_binary(state),
       do: packet["continuation_format"] != 4

  defp legacy_checkpoint?(_), do: false

  defp legacy_checkpoint?(packet, config, profile) do
    case Alto.Contrib.Resident.Config.resolve(config, profile) do
      {:ok, options} ->
        Keyword.get(options, :runner, Alto.Runner.Serial) == Alto.Runner.Serial and
          legacy_checkpoint?(packet)

      _ ->
        false
    end
  end

  defp checkpoint_upgrade_check(packet, config, profile) do
    if legacy_checkpoint?(packet, config, profile),
      do: {:error, :checkpoint_upgrade_required},
      else: :ok
  end

  defp task_status({:checkpointed, _, _}, _, _), do: "waiting_approval"

  defp task_status({:decided, class, _}, _, _) when class in [:unknown, :requires_operator],
    do: "requires_operator"

  defp task_status({:decided, class, evidence}, _, _),
    do:
      evidence[:status] || evidence["status"] ||
        if(class == :completed, do: "completed", else: "failed")

  defp task_status(_, _, active) when not is_nil(active), do: "running"
  defp task_status({:dispatched, _}, _, _), do: "starting"
  defp task_status(_, nil, _), do: "awaiting_admission"
  defp task_status(_, _, _), do: "queued"

  defp cancel_task(state, id) do
    case OperationLog.request(state.ledger, {:status, id}) do
      {:checkpointed, _, _} ->
        with {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}),
             {:ok, _} <-
               OperationLog.request(
                 state.ledger,
                 {:resume_checkpoint, id, recovered.revision,
                  %{
                    "decision" => "cancel"
                  }}
               ) do
          cancel_pending(state, id)
        end

      _ ->
        case state.active[id] do
          %{run_id: run} ->
            with :ok <- Runs.request(Service.registry(state.name), {:cancel, run, "user"}),
                 do: {:ok, %{"task_id" => id, "status" => "cancellation_requested"}}

          nil ->
            cancel_pending(state, id)
        end
    end
  end

  defp cancel_pending(state, id) do
    with :ok <- ensure_cancel_intent(state, id),
         {:ok, recovered} <- OperationLog.request(state.ledger, {:recovery, id}),
         :ok <-
           OperationLog.request(
             state.ledger,
             {:reject_intended, id, recovered.revision,
              %{
                status: "cancelled"
              }}
           ),
         :ok <- remove_cancelled_record(state, id) do
      {:ok, %{"task_id" => id, "status" => "cancelled"}}
    end
  end

  defp ensure_cancel_intent(state, id) do
    case find_record(state, id) do
      {:ok, record} ->
        OperationLog.request(
          state.ledger,
          {:intent, id, "alto_resident_task", id,
           %{
             key: id,
             generation_id: record.generation_id,
             payload: record.payload
           }}
        )

      {:error, :not_found} ->
        if OperationLog.request(state.ledger, {:status, id}) == {:intended},
          do: :ok,
          else: {:error, :not_found}
    end
  end

  defp remove_cancelled_record(state, id) do
    case find_record(state, id) do
      {:ok, record} ->
        case Queue.request(state.queue, {:cancel_pending, record.key}) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          # A consumer racing this cleanup sees the decided ledger and acks
          # without dispatch. An earlier dispatch would have fenced rejection.
          {:error, {:key_claimed, _}} -> :ok
          error -> error
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp restore_if_retry(_state, _id, resolution, _recovered) when resolution != :retry_permitted,
    do: :ok

  defp restore_if_retry(state, id, :retry_permitted, recovered) do
    data = recovered.recovery

    case Queue.request(
           state.queue,
           {:restore, id, data.generation_id, data.payload,
            [recovery_revision: recovered.revision]}
         ) do
      {:ok, _} -> :ok
      {:error, :duplicate} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reconcile_restart(state) do
    # No consumers have started yet. A persisted dispatch cannot prove whether
    # an external participant committed; park it before any queue claim resumes.
    with :ok <-
           Alto.Result.each(OperationLog.request(state.ledger, {:entries, :all}), fn entry ->
             id = entry.operation_key

             case entry.status do
               {:dispatched, attempt} ->
                 OperationLog.request(
                   state.ledger,
                   {:outcome, id, attempt, :requires_operator,
                    %{park_reason: :resident_restarted}}
                 )

               {:intended} ->
                 case repair_admission(state, id) do
                   {:error, :queue_full} -> :ok
                   result -> result
                 end

               {:decided, :rejected_before_dispatch, evidence} ->
                 if (evidence[:status] || evidence["status"]) == "cancelled",
                   do: remove_cancelled_record(state, id),
                   else: :ok

               _ ->
                 :ok
             end
           end),
         do: release_recovered_claims(state)
  end

  defp release_recovered_claims(state) do
    state.queue
    |> queue_records()
    |> Enum.filter(&(&1.status == :claimed))
    |> Alto.Result.each(fn record ->
      resolution =
        case OperationLog.request(state.ledger, {:status, operation_key(record)}) do
          {status, _, _} when status in [:checkpointed, :decided] -> :ack
          _ -> :release
        end

      Queue.request(state.queue, {:settle, record.claim_id, resolution, []})
    end)
  end

  defp valid_selection?(ids),
    do: is_list(ids) and length(ids) <= 100 and Enum.all?(ids, &is_binary/1)

  defp list_tasks(state, session_ids, ids) do
    records =
      state.queue |> queue_records() |> Enum.reverse() |> Map.new(&{operation_key(&1), &1})

    recoveries =
      Map.new(OperationLog.request(state.ledger, {:entries, :all}), &{&1.operation_key, &1})

    tasks =
      Enum.uniq(Map.keys(records) ++ Map.keys(recoveries))
      |> Enum.map(&describe(state, &1, records[&1], recoveries[&1]))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1["created_at_ms"] || 0, &1["id"]}, :desc)

    # A visible saved session must retain its newest durable task identity even
    # when that task has fallen outside the default listing window.
    by_session = Map.new(Enum.reverse(tasks), &{&1["session_id"], &1})
    by_id = Map.new(tasks, &{&1["id"], &1})
    requested = Enum.map(session_ids, &by_session[&1]) ++ Enum.map(ids, &by_id[&1])

    %{
      "tasks" =>
        (Enum.take(tasks, 100) ++ Enum.reject(requested, &is_nil/1))
        |> Enum.uniq_by(& &1["id"])
        |> Enum.map(&task_summary/1),
      "truncated" => length(tasks) > 100
    }
  end

  defp task_summary(task) do
    task
    |> Map.drop(["evidence", "approval"])
    |> Map.put("task", String.slice(task["task"] || "", 0, 120))
    |> Map.put("task_preview", true)
  end

  defp may_reconcile(state, id) do
    case {state.active[id], OperationLog.request(state.ledger, {:status, id})} do
      {nil, {:decided, class, _}} when class in [:unknown, :requires_operator] -> :ok
      _ -> {:error, :task_not_parked}
    end
  end

  defp parent_retry_check(state, id, :retry_permitted, payload) do
    {:ok, recovered} = OperationLog.request(state.ledger, {:recovery, id})

    case get_in(recovered.recovery, [:payload, "parent_store"]) do
      nil ->
        :ok

      _ ->
        if(Map.get(payload, :parent_recovery) == true,
          do: :ok,
          else: {:error, :use_parent_recovery}
        )
    end
  end

  defp parent_retry_check(_, _, _, _), do: :ok

  defp find_record(state, id) do
    case Enum.find(queue_records(state.queue), &(operation_key(&1) == id)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp repair_admission(state, id) do
    {:ok, recovered} = OperationLog.request(state.ledger, {:recovery, id})

    cancelling =
      get_in(recovered, [:checkpoint_decision, "decision"]) == "cancel" and
        recovered.revision == Map.get(recovered, :checkpoint_grant_revision)

    cond do
      cancelling ->
        # The old checkpoint claim can still exist if cancellation raced its
        # ack. Persist rejection before releasing or reclaiming any delivery.
        with :ok <-
               OperationLog.request(
                 state.ledger,
                 {:reject_intended, id, recovered.revision,
                  %{
                    status: "cancelled"
                  }}
               ),
             do: remove_cancelled_record(state, id)

      match?({:ok, _}, find_record(state, id)) ->
        :ok

      recovered.current_attempt ->
        restore_if_retry(state, id, :retry_permitted, recovered)

      true ->
        OperationLog.request(
          state.ledger,
          {:reject_intended, id, recovered.revision, %{status: "cancelled"}}
        )
    end
  end

  defp queue_records(queue) do
    {:ok, %{records: records}} = Queue.request(queue, {:snapshot_page, 0, 100})
    records
  end

  defp operation_key(record), do: record.operation_key || record.key
end
