defmodule Alto.Runner.Checkpoint do
  @moduledoc """
  Exact, bounded continuations at an approval boundary. The caller persists the
  packet and must fence its use with a durable dispatch/decision ledger.

  Only declared loop checkpoint callbacks are used. Live capabilities (pids,
  ports, references and functions) cannot be persisted. Configuration and tool
  code fingerprints must match on restore. Provider configuration is excluded;
  exact messages and tool values can still contain sensitive information and
  require private storage. Prepared values restore exactly, without preparation.
  """
  alias Alto.Runner.Budget
  alias Alto.Persistence.Codec
  alias Alto.OperationLog
  @limit 1_000_000
  @continuation_format 1
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
    :agent_identity
  ]

  def capture(run, pending, remaining, terminal) do
    driver = run.spec.driver
    frame = %{pending: pending, remaining: remaining, terminal: terminal}

    with true <- is_binary(run.checkpoint_version) and run.checkpoint_version != "",
         true <- function_exported?(driver, :dump_checkpoint, 2),
         true <- function_exported?(driver, :load_checkpoint, 2),
         true <- run.agent_depth == 0,
         {:ok, captured} <- capture_state(run, @fields, frame) do
      packet = checkpoint_packet(run, captured, Budget.snapshot(run.budget))
      {:ok, Map.put(packet, "request", Alto.Protocol.encode_term(pending.request))}
    else
      false -> {:error, :checkpoint_not_supported}
      {:error, _} = error -> error
      _ -> {:error, :invalid_loop_checkpoint}
    end
  rescue
    _ -> {:error, :invalid_loop_checkpoint}
  end

  def restore(
        run,
        %{"format" => 1, "continuation_format" => @continuation_format} = packet,
        decision,
        opts
      ) do
    with true <- is_nil(packet["kind"]),
         true <- decision in [:approve, :deny],
         true <- function_exported?(run.spec.driver, :load_checkpoint, 2),
         {:ok,
          %{run: saved, loop: loop, pending: pending, remaining: remaining, terminal: terminal} =
            decoded} <- decode_state(run, packet, @fields),
         true <- map_size(decoded) == 5,
         {:ok, state} <- run.spec.driver.load_checkpoint(loop, run.spec),
         {:ok, budget} <- Budget.restore(opts, packet["budget"]),
         true <- saved.transcript_bytes <= run.max_transcript_bytes,
         true <- within_budget?(budget) do
      {:ok, restore_run(run, saved, state, budget),
       %{pending: pending, remaining: remaining, terminal: terminal, decision: decision}}
    else
      false -> {:error, :checkpoint_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def restore(_, _, _, _), do: {:error, :invalid_checkpoint}

  @parent_fields @fields ++ [:persistence_errors]
  @authority_fields [
    :max_steps,
    :max_agent_depth,
    :max_tool_result_bytes,
    :max_transcript_bytes,
    :max_approval_details_bytes,
    :max_events,
    :provider_timeout,
    :tool_timeout,
    :approval_timeout
  ]
  @parent_packet_fields ~w(format continuation_format kind version fingerprint state budget session_id transcript_revision expires_at_ms)

  @doc """
  Capture a root parent's pending child join or its exact next frame.

  This only constructs a portable packet; the host must save it before child
  dispatch and fence consumption durably. Descendant reservations require a
  shared durable budget account. Carry `expires_at_ms` into the live run's
  `parent_expires_at_ms` before capturing its subsequent frame.
  """
  def capture_parent(run, pending, remaining, terminal) do
    frame = %{pending: pending, remaining: remaining, terminal: terminal}

    with :ok <- parent_capabilities(run),
         true <- valid_parent_pending?(pending),
         true <- valid_frame?(remaining, terminal),
         {:ok, store} <- OperationLog.identity(run.continuation_store, 100),
         authority <- Map.take(run, @authority_fields),
         true <- valid_authority?(authority),
         expires <- parent_expiry(run),
         true <- is_integer(expires),
         :ok <- unexpired(expires),
         budget <- Budget.snapshot(run.budget),
         binding <- %{
           store: store,
           authority: authority,
           expires_at_ms: expires,
           budget: budget,
           session_id: run.session
         },
         {:ok, captured} <- capture_state(run, @parent_fields, frame, %{binding: binding}),
         true <- valid_parent_saved?(captured.saved, authority) do
      packet =
        run
        |> checkpoint_packet(captured, budget)
        |> Map.merge(%{
          "kind" => "parent",
          "expires_at_ms" => expires
        })

      # Bound the envelope too, not merely its encoded state.
      with {:ok, _} <- encode(packet), do: {:ok, packet}
    else
      false -> {:error, :invalid_parent_checkpoint}
      {:error, _} = error -> error
      _ -> {:error, :invalid_parent_checkpoint}
    end
  rescue
    _ -> {:error, :invalid_parent_checkpoint}
  catch
    :exit, _ -> {:error, :parent_checkpoint_store_unavailable}
  end

  @doc "Restore a saved root parent without dispatching children or consuming its frame."
  def restore_parent(run, packet, opts) when is_map(packet) and is_list(opts) do
    with :ok <- parent_capabilities(run),
         true <- Enum.sort(Map.keys(packet)) == Enum.sort(@parent_packet_fields),
         true <- packet["format"] == 1 and packet["continuation_format"] == @continuation_format,
         true <- packet["kind"] == "parent",
         {:ok, _} <- encode(packet),
         {:ok, store} <- OperationLog.identity(run.continuation_store, 100),
         {:ok,
          %{
            run: saved,
            loop: loop,
            pending: pending,
            remaining: remaining,
            terminal: terminal,
            binding: binding
          } = decoded} <- decode_state(run, packet, @parent_fields),
         true <- map_size(decoded) == 6,
         true <- valid_parent_binding?(binding, packet) and binding.store == store,
         :ok <- parent_budget_binding(run, packet["budget"]),
         true <- valid_parent_pending?(pending),
         true <- valid_frame?(remaining, terminal),
         true <- valid_parent_saved?(saved, binding.authority),
         true <- valid_authority?(Map.take(run, @authority_fields)),
         authority <- narrow_authority(run, binding.authority),
         true <- saved.transcript_bytes <= authority.max_transcript_bytes,
         true <- packet["session_id"] == run.session,
         :ok <- unexpired(binding.expires_at_ms),
         {:ok, state} <- run.spec.driver.load_checkpoint(loop, run.spec),
         {:ok, budget} <- Budget.restore(opts, packet["budget"]),
         budget <- clamp_parent_deadline(budget, binding.expires_at_ms),
         :ok <- Budget.check(budget),
         true <- within_budget?(budget) do
      restored =
        restore_run(run, saved, state, budget)
        |> Map.merge(authority)
        |> Map.put(:parent_expires_at_ms, binding.expires_at_ms)

      {:ok, restored, %{pending: pending, remaining: remaining, terminal: terminal}}
    else
      false -> {:error, :checkpoint_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_parent_checkpoint}
    end
  catch
    :exit, _ -> {:error, :parent_checkpoint_store_unavailable}
  end

  def restore_parent(_, _, _), do: {:error, :invalid_parent_checkpoint}

  @doc "Capture an independently suspended child with immutable inherited authority."
  def capture_child(run, pending, remaining, terminal) do
    with %Alto.Subagents.Continuation.Ticket{} = ticket <- Map.get(run, :subagent_ticket),
         true <- run.agent_depth > 0,
         true <- is_map(run.child_profile) and not Map.has_key?(run.child_profile, :provider),
         true <- is_struct(run.budget.account, Budget.Account),
         {:ok, store} <- OperationLog.identity(ticket.batch.ledger, 100),
         {:ok, packet} <- capture(%{run | agent_depth: 0}, pending, remaining, terminal),
         authority <- Map.take(run, @authority_fields),
         true <- valid_authority?(authority),
         expiry <- parent_expiry(run),
         :ok <- unexpired(expiry),
         binding <- %{
           journal: Alto.Subagents.Continuation.identity(ticket.batch),
           store: store,
           id: ticket.id,
           attempt: ticket.attempt,
           profile: run.child_profile,
           authority: authority,
           expires_at_ms: expiry,
           agent_depth: run.agent_depth,
           cwd: run.tool_context.cwd,
           resume_snapshot: run.resume_snapshot,
           budget: packet["budget"],
           session_id: run.session
         },
         {:ok, child} <- encode(binding),
         result <- Map.merge(packet, %{"kind" => "child", "child" => child}),
         {:ok, _} <- encode(result) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :child_checkpoint_not_supported}
    end
  rescue
    _ -> {:error, :child_checkpoint_not_supported}
  end

  @doc "Inspect the bounded saved child profile; grants remain owned by its journal."
  def child_binding(%{"kind" => "child", "child" => child}), do: decode(child)
  def child_binding(_), do: {:error, :invalid_child_checkpoint}

  @doc "Validate the exact child checkpoint before consuming its explicit decision."
  def restore_child(run, packet, decision, opts) do
    with {:ok, binding} <- child_binding(packet),
         %Alto.Subagents.Continuation.Ticket{} = ticket <- Map.get(run, :subagent_ticket),
         {:ok, store} <- OperationLog.identity(ticket.batch.ledger, 100),
         true <- binding.journal == Alto.Subagents.Continuation.identity(ticket.batch),
         true <-
           binding.store == store and binding.id == ticket.id and
             binding.attempt == ticket.attempt,
         true <- binding.agent_depth == run.agent_depth and run.agent_depth > 0,
         true <- binding.session_id == run.session and packet["session_id"] == run.session,
         true <-
           binding.budget == packet["budget"] and is_struct(run.budget.account, Budget.Account),
         true <- binding.profile == run.child_profile and binding.cwd == run.tool_context.cwd,
         true <- binding.resume_snapshot == run.resume_snapshot,
         true <- valid_authority?(binding.authority),
         :ok <- parent_budget_binding(run, binding.budget),
         :ok <- unexpired(binding.expires_at_ms),
         {:ok, restored, frame} <-
           restore(run, Map.drop(packet, ["kind", "child"]), decision, opts),
         true <- length(restored.agent_identity.path) == binding.agent_depth,
         authority <- narrow_authority(run, binding.authority),
         true <- restored.transcript_bytes <= authority.max_transcript_bytes,
         budget <- clamp_parent_deadline(restored.budget, binding.expires_at_ms),
         :ok <- Budget.check(budget) do
      {:ok,
       restored
       |> Map.merge(authority)
       |> Map.put(:budget, budget)
       |> Map.put(:parent_expires_at_ms, binding.expires_at_ms), frame}
    else
      {:error, _} = error -> error
      _ -> {:error, :child_checkpoint_mismatch}
    end
  end

  defp capture_state(run, fields, frame, extras \\ %{}) do
    with {:ok, loop} <- run.spec.driver.dump_checkpoint(run.loop_state, run.spec),
         {:ok, revision} <- transcript_revision(run),
         true <- run.transcript_revision in [:any, revision],
         saved <- Map.take(%{run | transcript_revision: revision}, fields),
         {:ok, fingerprint} <- fingerprint(run),
         state <- Map.merge(%{run: saved, loop: loop}, Map.merge(frame, extras)),
         {:ok, encoded} <- encode(state) do
      {:ok, %{saved: saved, revision: revision, fingerprint: fingerprint, encoded: encoded}}
    end
  end

  defp checkpoint_packet(run, captured, budget) do
    %{
      "format" => 1,
      "continuation_format" => @continuation_format,
      "version" => run.checkpoint_version,
      "fingerprint" => captured.fingerprint,
      "state" => captured.encoded,
      "budget" => budget,
      "session_id" => run.session,
      "transcript_revision" => captured.revision
    }
  end

  defp decode_state(run, packet, fields) do
    with true <-
           is_binary(run.checkpoint_version) and packet["version"] == run.checkpoint_version,
         {:ok, fingerprint} <- fingerprint(run),
         true <- packet["fingerprint"] == fingerprint,
         {:ok, decoded} <- decode(packet["state"]),
         true <- is_map(decoded),
         %{run: saved} <- decoded,
         true <- is_map(saved) and Enum.sort(Map.keys(saved)) == Enum.sort(fields),
         true <- valid_compaction_state?(saved),
         true <- valid_history_state?(saved),
         true <- saved.transcript_revision == packet["transcript_revision"],
         true <- Alto.AgentIdentity.valid?(saved.agent_identity),
         {:ok, revision} <- transcript_revision(run),
         true <- revision == saved.transcript_revision do
      {:ok, decoded}
    end
  end

  defp restore_run(run, saved, loop_state, budget) do
    run
    |> Map.merge(saved)
    |> Map.put(:loop_state, loop_state)
    |> Map.put(:budget, budget)
    |> Map.update!(:tool_context, &Map.put(&1, :agent_identity, saved.agent_identity))
  end

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

  defp valid_parent_binding?(binding, packet) when is_map(binding) do
    map_size(binding) == 5 and valid_authority?(binding.authority) and
      binding.budget == packet["budget"] and
      binding.session_id == packet["session_id"] and
      binding.expires_at_ms == packet["expires_at_ms"]
  end

  defp valid_parent_binding?(_, _), do: false

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

  defp valid_parent_saved?(saved, authority) when is_map(saved) do
    Enum.sort(Map.keys(saved)) == Enum.sort(@parent_fields) and
      Alto.AgentIdentity.valid?(saved.agent_identity) and saved.agent_identity.path == [] and
      is_list(saved.messages_rev) and Enum.all?(saved.messages_rev, &is_map/1) and
      is_integer(saved.transcript_bytes) and saved.transcript_bytes >= 0 and
      saved.transcript_bytes <= authority.max_transcript_bytes and
      Alto.Context.Transcript.bytes(saved.messages_rev) == saved.transcript_bytes and
      is_integer(saved.transcript_revision) and saved.transcript_revision >= 0 and
      is_integer(saved.model_requests) and saved.model_requests >= 0 and
      is_integer(saved.op_seq) and saved.op_seq >= 0 and
      valid_usage?(saved.usage) and is_list(saved.persistence_errors) and
      valid_compaction_state?(saved) and valid_history_state?(saved) and
      valid_pending_calls?(saved.pending_provider_calls) and
      (is_nil(saved.request_model_tools) or match?(%MapSet{}, saved.request_model_tools)) and
      saved.verdict in [:empty, :completed, :rejected_before_dispatch, :failed_known, :unknown]
  end

  defp valid_parent_saved?(_, _), do: false

  defp valid_compaction_state?(saved) do
    is_integer(saved.compaction_count) and saved.compaction_count >= 0
  end

  defp valid_history_state?(saved) do
    is_list(saved.resolved_operations) and length(saved.resolved_operations) <= 256 and
      Enum.all?(saved.resolved_operations, &(is_binary(&1) and byte_size(&1) in 1..512))
  end

  defp valid_usage?(%Alto.Usage{} = usage),
    do: Enum.all?(Map.from_struct(usage), fn {_, value} -> is_integer(value) and value >= 0 end)

  defp valid_usage?(_), do: false

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
      {:ok, %{revision: revision}} -> {:ok, revision}
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
        {name, tool.module, tool.module.module_info(:md5), tool.opts, tool.approval,
         tool.preparation}
      end)
      |> Enum.sort()

    data =
      {@continuation_format, run.spec.driver, run.spec.driver.module_info(:md5),
       run.spec.driver_options, run.spec.middleware, stable_subagents(run.spec.subagents), tools,
       run.model_tools, run.tool_context.cwd, Map.get(run, :session_history, :completed),
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

  defp fingerprint_data(%module{} = value) do
    if Alto.Subagents.Policy.implementation?(module),
      do: stable_subagents(value),
      else:
        Map.new(Map.to_list(value), fn {k, v} -> {fingerprint_data(k), fingerprint_data(v)} end)
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
        OperationLog.identity(value, 100)
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
