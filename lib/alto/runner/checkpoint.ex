defmodule Alto.Runner.Checkpoint do
  @moduledoc """
  Exact, bounded continuations at an approval boundary. The caller persists the
  packet and must fence its use with a durable dispatch/decision ledger.

  See `docs/checkpoints.md#portability-and-bounds` for restoration and storage constraints.
  """
  alias Alto.Runner.Budget
  alias Alto.Persistence.Codec
  alias Alto.OperationLog
  @limit 1_000_000
  @continuation_format 4
  @fields [
    :messages_rev,
    :transcript_bytes,
    :model_requests,
    :usage,
    :verdict,
    :op_seq,
    :pending_provider_calls,
    :request_model_tools,
    :transcript_revision,
    :compaction_count,
    :resolved_operations,
    :agent_identity,
    :communication,
    :async_children,
    :persistence_errors
  ]

  @authority_fields Alto.Config.authority_fields()
  @packet_fields ~w(format continuation_format kind state session_id messaging_id transcript_revision request)

  def capture(run, pending, remaining, terminal),
    do: capture_snapshot(run, nil, pending.job, remaining, terminal, pending.request)

  def restore(run, packet, decision, opts),
    do: restore_snapshot(run, packet, nil, decision, opts)

  @doc "Capture a root parent's pending child join or its exact next frame."
  def capture_parent(run, pending, remaining, terminal),
    do: capture_snapshot(run, "parent", pending, remaining, terminal)

  @doc "Restore a saved root parent without consuming its durable grant."
  def restore_parent(run, packet, opts),
    do: restore_snapshot(run, packet, "parent", nil, opts)

  @doc "Capture an independently suspended child with immutable inherited authority."
  def capture_child(run, pending, remaining, terminal),
    do: capture_snapshot(run, "child", pending.job, remaining, terminal, pending.request)

  @doc "Inspect the saved child profile; grants remain owned by its journal."
  def child_binding(%{"kind" => "child", "state" => state}) do
    with {:ok, %{binding: binding}} <- decode(state), do: {:ok, binding}
  end

  def child_binding(_), do: {:error, :invalid_child_checkpoint}

  @doc "Validate a child checkpoint before consuming its explicit decision."
  def restore_child(run, packet, decision, opts),
    do: restore_snapshot(run, packet, "child", decision, opts)

  @doc false
  def capture_execution(run, effects, terminal),
    do: capture_snapshot(run, "execution", :frame, effects, terminal)

  @doc false
  def restore_execution(run, packet) do
    with {:ok, restored, frame} <- restore_snapshot(run, packet, "execution", nil, []) do
      {:ok, restored, %{effects: frame.remaining, terminal: frame.terminal}}
    end
  end

  defp capture_snapshot(run, kind, pending, remaining, terminal, request \\ nil) do
    with {:ok, binding} <- capture_binding(kind, run),
         true <- is_binary(run.checkpoint_version) and run.checkpoint_version != "",
         true <- function_exported?(run.spec.driver, :dump_checkpoint, 2),
         true <- function_exported?(run.spec.driver, :load_checkpoint, 2),
         true <- valid_pending?(kind, pending) and valid_frame?(remaining, terminal),
         {:ok, children} <- capture_agents(run),
         {:ok, communication} <- capture_messaging(run, kind != "parent"),
         {:ok, loop} <- run.spec.driver.dump_checkpoint(run.loop_state, run.spec),
         {:ok, revision} <- transcript_revision(run),
         true <- run.transcript_revision in [:any, revision],
         saved <-
           Map.take(
             Map.merge(run, %{
               transcript_revision: revision,
               communication: communication,
               async_children: children
             }),
             @fields
           ),
         true <- valid_saved?(saved, Map.take(run, @authority_fields)),
         {:ok, fingerprint} <- fingerprint(run),
         {:ok, state} <-
           encode(%{
             run: saved,
             loop: loop,
             binding: binding,
             frame: %{pending: pending, remaining: remaining, terminal: terminal},
             budget: Budget.snapshot(run.budget),
             version: run.checkpoint_version,
             fingerprint: fingerprint,
             session_id: run.session,
             messaging_id: messaging_id(run)
           }),
         packet <- %{
           "format" => 1,
           "continuation_format" => @continuation_format,
           "kind" => kind,
           "state" => state,
           "session_id" => run.session,
           "messaging_id" => messaging_id(run),
           "transcript_revision" => revision,
           "request" => request && Alto.Protocol.encode_term(request)
         },
         true <- Codec.valid?(packet, max_bytes: 2 * @limit) do
      {:ok, packet}
    else
      {:error, _} = error -> error
      _ -> {:error, capture_error(kind)}
    end
  rescue
    _ -> {:error, capture_error(kind)}
  end

  defp restore_snapshot(run, packet, kind, decision, opts) do
    with true <- is_map(packet) and is_list(opts),
         true <- Enum.sort(Map.keys(packet)) == Enum.sort(@packet_fields),
         true <- packet["format"] == 1 and packet["continuation_format"] == @continuation_format,
         true <- packet["kind"] == kind,
         true <- kind not in [nil, "child"] or decision in [:approve, :deny],
         true <- Codec.valid?(packet, max_bytes: 2 * @limit),
         {:ok,
          %{
            run: saved,
            loop: _,
            binding: _,
            frame: frame,
            budget: _,
            version: _,
            fingerprint: _,
            session_id: _,
            messaging_id: _
          } = data} <-
           decode(packet["state"]),
         true <- map_size(data) == 9 and is_map(saved) and is_map(data.budget),
         %{pending: _, remaining: _, terminal: _} <- frame,
         true <- map_size(frame) == 3,
         true <- data.version == run.checkpoint_version and is_binary(data.version),
         {:ok, fingerprint} <- fingerprint(run),
         true <- data.fingerprint == fingerprint,
         true <- data.session_id == packet["session_id"],
         true <- data.messaging_id == packet["messaging_id"],
         true <-
           is_nil(data.messaging_id) or is_nil(messaging_id(run)) or
             data.messaging_id == messaging_id(run),
         :ok <- validate_binding(kind, run, data),
         authority <- checkpoint_authority(run, data.binding),
         true <- valid_saved?(data.run, authority),
         true <- not is_nil(data.messaging_id) or is_nil(data.run.communication),
         true <- data.run.transcript_revision == packet["transcript_revision"],
         {:ok, revision} <- transcript_revision(run),
         true <- revision == data.run.transcript_revision,
         true <-
           valid_pending?(kind, data.frame.pending) and
             valid_frame?(data.frame.remaining, data.frame.terminal),
         {:ok, state} <- run.spec.driver.load_checkpoint(data.loop, run.spec),
         {:ok, budget} <- restore_budget(kind, run, data, opts),
         true <- within_budget?(budget),
         {:ok, restored} <- restore_run(Map.merge(run, authority), data.run, state, budget) do
      restored =
        if data.binding,
          do: Map.put(restored, :parent_expires_at_ms, data.binding.expires_at_ms),
          else: restored

      {:ok, restored, data.frame}
    else
      {:error, _} = error -> error
      _ -> {:error, :checkpoint_mismatch}
    end
  end

  defp capture_binding(nil, %{agent_depth: 0}), do: {:ok, nil}

  defp capture_binding("execution", %{workspaces: nil, continuation_store: nil}),
    do: {:ok, nil}

  defp capture_binding(kind, run) when kind in ["parent", "child"] do
    with :ok <- binding_capabilities(kind, run),
         {:ok, store} <- store_identity(kind, run),
         authority <- Map.take(run, @authority_fields),
         true <- valid_authority?(authority),
         expiry <- parent_expiry(run),
         :ok <- unexpired(expiry) do
      common = %{store: store, authority: authority, expires_at_ms: expiry}

      binding =
        if kind == "parent",
          do: common,
          else:
            Map.merge(common, %{
              journal: Alto.Subagents.Continuation.identity(run.subagent_ticket.batch),
              id: run.subagent_ticket.id,
              attempt: run.subagent_ticket.attempt,
              profile: run.child_profile,
              agent_depth: run.agent_depth,
              cwd: run.cwd,
              resume_snapshot: run.resume_snapshot
            })

      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, capture_error(kind)}
    end
  end

  defp capture_binding(kind, _), do: {:error, capture_error(kind)}

  defp validate_binding(kind, run, %{binding: nil}) when kind in [nil, "execution"] do
    if kind != "execution" or run.agent_depth > 0, do: :ok, else: {:error, :checkpoint_mismatch}
  end

  defp validate_binding(kind, run, data) when kind in ["parent", "child"] do
    binding = data.binding

    with :ok <- binding_capabilities(kind, run),
         %{store: _, authority: authority, expires_at_ms: _} <- binding,
         true <- valid_authority?(authority),
         true <- Alto.AgentIdentity.valid?(Map.get(data.run, :agent_identity)),
         {:ok, store} <- store_identity(kind, run),
         true <- binding.store == store and data.session_id == run.session,
         :ok <- parent_budget_binding(run, data.budget),
         :ok <- unexpired(binding.expires_at_ms) do
      valid =
        if kind == "parent" do
          map_size(binding) == 3 and data.run.agent_identity.path == []
        else
          ticket = run.subagent_ticket

          Enum.sort(Map.keys(binding)) ==
            Enum.sort([
              :store,
              :authority,
              :expires_at_ms,
              :journal,
              :id,
              :attempt,
              :profile,
              :agent_depth,
              :cwd,
              :resume_snapshot
            ]) and
            binding.journal == Alto.Subagents.Continuation.identity(ticket.batch) and
            binding.id == ticket.id and binding.attempt == ticket.attempt and
            binding.agent_depth == run.agent_depth and
            length(data.run.agent_identity.path) == binding.agent_depth and
            binding.profile == run.child_profile and binding.cwd == run.cwd and
            binding.resume_snapshot == run.resume_snapshot
        end

      if valid, do: :ok, else: {:error, :checkpoint_mismatch}
    else
      {:error, _} = error -> error
      _ -> {:error, :checkpoint_mismatch}
    end
  end

  defp validate_binding(_, _, _), do: {:error, :checkpoint_mismatch}

  defp binding_capabilities("parent", run), do: parent_capabilities(run)

  defp binding_capabilities("child", run) do
    if match?(%Alto.Subagents.Continuation.Ticket{}, Map.get(run, :subagent_ticket)) and
         run.agent_depth > 0 and is_map(run.child_profile) and
         not Map.has_key?(run.child_profile, :provider) and
         is_struct(run.budget.account, Budget.Account),
       do: :ok,
       else: {:error, :child_checkpoint_not_supported}
  end

  defp binding_store("parent", run), do: run.continuation_store
  defp binding_store("child", run), do: run.subagent_ticket.batch.ledger

  defp store_identity(kind, run) do
    OperationLog.request(binding_store(kind, run), :identity, 100)
  catch
    :exit, _ -> {:error, :parent_checkpoint_store_unavailable}
  end

  defp checkpoint_authority(run, nil), do: Map.take(run, @authority_fields)
  defp checkpoint_authority(run, binding), do: narrow_authority(run, binding.authority)

  defp restore_budget(kind, run, data, opts) do
    with {:ok, budget} <-
           if(kind == "execution",
             do: {:ok, run.budget},
             else: Budget.restore(opts, data.budget)
           ),
         budget <-
           if(data.binding,
             do: clamp_parent_deadline(budget, data.binding.expires_at_ms),
             else: budget
           ),
         :ok <- Budget.check(budget),
         do: {:ok, budget}
  end

  defp valid_pending?("parent", pending), do: valid_parent_pending?(pending)
  defp valid_pending?("execution", pending), do: pending == :frame
  defp valid_pending?(_, pending), do: is_map(pending)

  defp capture_error("parent"), do: :invalid_parent_checkpoint
  defp capture_error("child"), do: :child_checkpoint_not_supported
  defp capture_error("execution"), do: :async_checkpoint_not_supported
  defp capture_error(_), do: :invalid_loop_checkpoint

  defp restore_run(run, saved, loop_state, budget) do
    restored =
      run
      |> Map.merge(saved)
      |> Map.put(:loop_state, loop_state)
      |> Map.put(:budget, budget)

    with :ok <- restore_messaging(run, saved.communication),
         :ok <- restore_agents(run, saved.async_children, restored) do
      {:ok, Map.put(restored, :activate_agents, true)}
    end
  end

  defp messaging_id(run), do: Map.get(Map.get(run, :messaging) || %{}, :id)

  defp capture_messaging(%{messaging: sender}, seal) when not is_nil(sender),
    do: Alto.Messaging.snapshot(sender, seal)

  defp capture_messaging(_, _), do: {:ok, nil}

  defp capture_agents(%{async_agents: agents} = run) when is_pid(agents),
    do: Alto.Runner.Agents.checkpoint(agents, run.budget)

  defp capture_agents(_), do: {:ok, []}

  defp restore_messaging(_, nil), do: :ok

  defp restore_messaging(run, saved), do: Alto.Messaging.restore(run.messaging, saved)

  defp restore_agents(%{async_agents: agents}, saved, restored) when is_pid(agents),
    do: Alto.Runner.Agents.restore(agents, saved, restored)

  defp restore_agents(_, [], _), do: :ok
  defp restore_agents(_, _, _), do: {:error, :checkpoint_mismatch}

  defp parent_capabilities(run) do
    cond do
      not match?(%Budget{account: %Budget.Account{}}, run.budget) ->
        {:error, :parent_checkpoint_requires_budget_account}

      run.agent_depth != 0 or is_nil(Map.get(run, :continuation_store)) or
        not is_binary(run.checkpoint_version) or run.checkpoint_version == "" or
        not Code.ensure_loaded?(run.spec.driver) or
        not function_exported?(run.spec.driver, :dump_checkpoint, 2) or
          not function_exported?(run.spec.driver, :load_checkpoint, 2) ->
        {:error, :checkpoint_not_supported}

      true ->
        :ok
    end
  end

  defp parent_expiry(run) do
    latest = System.system_time(:millisecond) + Budget.remaining(run.budget)

    case Map.get(run, :parent_expires_at_ms) do
      nil -> latest
      expiry when is_integer(expiry) -> min(expiry, latest)
      _ -> :invalid
    end
  end

  defp unexpired(expiry) when is_integer(expiry) do
    if expiry > System.system_time(:millisecond), do: :ok, else: {:error, :run_timeout}
  end

  defp unexpired(_), do: {:error, :invalid_parent_checkpoint}

  defp clamp_parent_deadline(budget, expiry) do
    remaining = max(expiry - System.system_time(:millisecond), 0)
    %{budget | deadline: min(budget.deadline, System.monotonic_time(:millisecond) + remaining)}
  end

  defp parent_budget_binding(run, snapshot) do
    if Budget.Account.identity(run.budget.account) == snapshot["account"],
      do: :ok,
      else: {:error, :budget_account_mismatch}
  end

  defp valid_authority?(authority) when is_map(authority) do
    Enum.sort(Map.keys(authority)) == Enum.sort(@authority_fields) and
      Enum.all?(authority, fn {key, value} ->
        is_integer(value) and value >= if(key in [:max_agent_depth, :max_events], do: 0, else: 1)
      end)
  end

  defp valid_authority?(_), do: false

  defp narrow_authority(run, saved),
    do: Map.new(saved, fn {key, value} -> {key, min(Map.fetch!(run, key), value)} end)

  defp valid_saved?(saved, authority) when is_map(saved) do
    Enum.sort(Map.keys(saved)) == Enum.sort(@fields) and
      Alto.AgentIdentity.valid?(saved.agent_identity) and
      is_list(saved.messages_rev) and Enum.all?(saved.messages_rev, &is_map/1) and
      is_integer(saved.transcript_bytes) and saved.transcript_bytes >= 0 and
      saved.transcript_bytes <= authority.max_transcript_bytes and
      Alto.Context.Transcript.bytes(saved.messages_rev) == saved.transcript_bytes and
      is_integer(saved.transcript_revision) and saved.transcript_revision >= 0 and
      is_integer(saved.model_requests) and saved.model_requests >= 0 and
      is_integer(saved.op_seq) and saved.op_seq >= 0 and
      is_struct(saved.usage, Alto.Usage) and Alto.Usage.valid?(saved.usage) and
      is_list(saved.persistence_errors) and
      valid_compaction_state?(saved) and valid_history_state?(saved) and
      valid_pending_calls?(saved.pending_provider_calls) and
      (is_nil(saved.request_model_tools) or match?(%MapSet{}, saved.request_model_tools)) and
      saved.verdict in [:empty, :completed, :rejected_before_dispatch, :failed_known, :unknown]
  rescue
    _ -> false
  end

  defp valid_saved?(_, _), do: false

  defp valid_compaction_state?(saved) do
    is_integer(saved.compaction_count) and saved.compaction_count >= 0
  end

  defp valid_history_state?(saved) do
    is_list(saved.resolved_operations) and length(saved.resolved_operations) <= 256 and
      Enum.all?(saved.resolved_operations, &(is_binary(&1) and byte_size(&1) in 1..512))
  end

  defp valid_pending_calls?(calls) when is_map(calls) do
    Enum.all?(calls, fn
      {{id, name}, count} -> is_binary(id) and is_binary(name) and is_integer(count) and count > 0
      _ -> false
    end)
  end

  defp valid_pending_calls?(_), do: false

  defp valid_parent_pending?(%{kind: :frame} = pending), do: map_size(pending) == 1

  defp valid_parent_pending?(%{kind: :children, ids: ids} = pending) do
    map_size(pending) == 2 and is_list(ids) and length(ids) in 1..64 and
      length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1)))
  end

  defp valid_parent_pending?(_), do: false

  defp valid_frame?(remaining, terminal) do
    is_list(remaining) and
      Enum.all?(remaining, fn
        %Alto.Effect{kind: kind, data: data} ->
          kind in [
            :emit,
            :request_model,
            :compact_context,
            :run_tool,
            :run_tools,
            :invoke_tool,
            :spawn_agents
          ] and
            is_map(data)

        _ ->
          false
      end) and
      (terminal == :continue or match?({:stop, _}, terminal) or match?({:error, _}, terminal))
  end

  defp transcript_revision(%{session: nil}), do: {:ok, 0}

  defp transcript_revision(run) do
    case Alto.Session.transcript(run.session, session_dir: run.session_dir) do
      {:ok, %{"revision" => revision}} -> {:ok, revision}
      {:error, :no_resumable_transcript} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  defp within_budget?(budget) do
    saved = Budget.snapshot(budget)

    saved["effects_used"] <= saved["max_effects"] and
      saved["model_requests_used"] <= saved["max_model_requests"]
  end

  defp fingerprint(run) do
    with {:ok, data} <- fingerprint_data_for(run) do
      {:ok,
       :crypto.hash(:sha256, :erlang.term_to_binary(data, [:deterministic]))
       |> Base.encode16(case: :lower)}
    end
  end

  defp fingerprint_data_for(run) do
    tools =
      Enum.map(run.tools, fn {name, tool} ->
        {name, tool.module, tool.module.module_info(:md5), tool.opts, tool.approval}
      end)
      |> Enum.sort()

    data =
      {@continuation_format, run.spec.driver, run.spec.driver.module_info(:md5),
       run.spec.driver_options, run.spec.middleware, stable_subagents(run.spec.subagents), tools,
       run.model_tools, run.cwd, Map.get(run, :session_history, :completed),
       Map.get(run, :max_conversation_bytes, 128_000_000)}

    {:ok, fingerprint_data(data)}
  catch
    {__MODULE__, :durable_identity_unavailable, reason} ->
      {:error, {:durable_identity_unavailable, reason}}
  end

  # Fun ETF includes its creating process. Bind the code and closed-over
  # environment instead so trusted pure argument functions survive a new VM.
  defp fingerprint_data(value) when is_function(value) do
    Enum.map([:module, :name, :arity, :index, :uniq, :env], fn key ->
      {^key, data} = :erlang.fun_info(value, key)
      {key, fingerprint_data(data)}
    end)
  end

  defp fingerprint_data({module, _options} = value) when is_atom(module) do
    if Alto.Subagents.Policy.implementation?(module),
      do: stable_subagents(value),
      else: value |> Tuple.to_list() |> Enum.map(&fingerprint_data/1) |> List.to_tuple()
  end

  defp fingerprint_data(value) when is_map(value),
    do: Map.new(Map.to_list(value), fn {k, v} -> {fingerprint_data(k), fingerprint_data(v)} end)

  defp fingerprint_data(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&fingerprint_data/1) |> List.to_tuple()

  defp fingerprint_data(value) when is_list(value), do: Enum.map(value, &fingerprint_data/1)
  defp fingerprint_data(value), do: value

  def encode(term) do
    case Codec.encode(term, max_bytes: @limit) do
      {:ok, _} = result -> result
      {:error, _} -> {:error, :checkpoint_not_portable_or_too_large}
    end
  end

  def decode(encoded) do
    case Codec.decode(encoded, max_bytes: @limit) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, :invalid_checkpoint_data}
    end
  end

  defp stable_subagents(nil), do: nil

  defp stable_subagents(policy) do
    Alto.Subagents.Policy.fingerprint(policy, &stable_resource/1) |> fingerprint_data()
  end

  defp stable_resource(nil), do: nil

  defp stable_resource(%Alto.Workspaces{} = manager) do
    %{
      "kind" => "alto_workspaces",
      "root" => manager.root,
      "backend" => manager.backend,
      "backend_md5" => module_md5(manager.backend),
      "backend_options" => manager.backend_options,
      "ledger" => stable_resource(manager.ledger)
    }
  end

  defp stable_resource(value) when is_pid(value) or is_atom(value) or is_tuple(value) do
    result =
      try do
        OperationLog.request(value, :identity, 100)
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, identity} -> identity
      {:error, reason} -> throw({__MODULE__, :durable_identity_unavailable, reason})
      other -> throw({__MODULE__, :durable_identity_unavailable, other})
    end
  end

  defp stable_resource(value), do: fingerprint_data(value)

  defp module_md5(module) when is_atom(module) do
    if Code.ensure_loaded?(module), do: module.module_info(:md5), else: :unavailable
  end

  defp module_md5(_), do: :unavailable
end
