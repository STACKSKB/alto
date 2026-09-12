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
    :compacted?,
    :agent_identity
  ]

  def capture(run, pending, remaining, terminal) do
    driver = run.spec.driver

    with true <- is_binary(run.checkpoint_version) and run.checkpoint_version != "",
         true <- function_exported?(driver, :dump_checkpoint, 2),
         true <- function_exported?(driver, :load_checkpoint, 2),
         true <- run.agent_depth == 0,
         {:ok, loop} <- driver.dump_checkpoint(run.loop_state, run.spec),
         {:ok, revision} <- transcript_revision(run),
         true <- run.transcript_revision in [:any, revision],
         run <- %{run | transcript_revision: revision},
         state <- %{
           run: Map.take(run, @fields),
           loop: loop,
           pending: pending,
           remaining: remaining,
           terminal: terminal
         },
         {:ok, encoded} <- encode(state) do
      {:ok,
       %{
         "format" => 1,
         "continuation_format" => @continuation_format,
         "version" => run.checkpoint_version,
         "fingerprint" => fingerprint(run),
         "state" => encoded,
         "budget" => Budget.snapshot(run.budget),
         "usage" => Alto.Protocol.encode_term(Alto.Usage.to_map(run.usage)),
         "agent_identity" => Alto.Protocol.encode_term(run.agent_identity),
         "session_id" => run.session,
         "transcript_revision" => revision,
         "request" => Alto.Protocol.encode_term(pending.request)
       }}
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
    with true <-
           packet["version"] == run.checkpoint_version and is_binary(run.checkpoint_version),
         true <- packet["fingerprint"] == fingerprint(run),
         true <- decision in [:approve, :deny],
         true <- function_exported?(run.spec.driver, :load_checkpoint, 2),
         {:ok,
          %{run: saved, loop: loop, pending: pending, remaining: remaining, terminal: terminal}} <-
           decode(packet["state"]),
         true <- is_map(saved) and Enum.sort(Map.keys(saved)) == Enum.sort(@fields),
         {:ok, state} <- run.spec.driver.load_checkpoint(loop, run.spec),
         {:ok, budget} <- Budget.restore(opts, packet["budget"]),
         true <- saved.transcript_bytes <= run.max_transcript_bytes,
         true <- saved.transcript_revision == packet["transcript_revision"],
         true <- valid_agent_identity?(saved.agent_identity),
         true <- packet["agent_identity"] == Alto.Protocol.encode_term(saved.agent_identity),
         {:ok, current_revision} <- transcript_revision(run),
         true <- current_revision == saved.transcript_revision,
         true <- within_budget?(budget) do
      restored =
        run
        |> Map.merge(saved)
        |> Map.put(:loop_state, state)
        |> Map.put(:budget, budget)
        |> Map.update!(:tool_context, &Map.put(&1, :agent_identity, saved.agent_identity))

      {:ok, restored,
       %{pending: pending, remaining: remaining, terminal: terminal, decision: decision}}
    else
      false -> {:error, :checkpoint_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_checkpoint}
    end
  rescue
    _ -> {:error, :invalid_checkpoint}
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
  @parent_packet_fields ~w(format continuation_format kind stage version fingerprint state budget usage agent_identity session_id transcript_revision store authority expires_at_ms)

  @doc """
  Capture a root parent's pending child join or its exact next frame.

  This only constructs a portable packet; the host must save it before child
  dispatch and fence consumption durably. Descendant reservations require a
  shared durable budget account. Carry `expires_at_ms` into the live run's
  `parent_expires_at_ms` before capturing its subsequent frame.
  """
  def capture_parent(run, pending, remaining, terminal) do
    with :ok <- parent_capabilities(run),
         true <- valid_parent_pending?(pending),
         true <- valid_frame?(remaining, terminal),
         {:ok, store} <- OperationLog.identity(run.continuation_store, 100),
         {:ok, loop} <- run.spec.driver.dump_checkpoint(run.loop_state, run.spec),
         {:ok, revision} <- transcript_revision(run),
         true <- run.transcript_revision in [:any, revision],
         saved <- Map.take(%{run | transcript_revision: revision}, @parent_fields),
         authority <- Map.take(run, @authority_fields),
         true <- valid_authority?(authority),
         true <- valid_parent_saved?(saved, authority),
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
         {:ok, encoded} <-
           encode(%{
             run: saved,
             loop: loop,
             pending: pending,
             remaining: remaining,
             terminal: terminal,
             binding: binding
           }) do
      packet = %{
        "format" => 1,
        "continuation_format" => @continuation_format,
        "kind" => "parent",
        "stage" => Atom.to_string(pending.kind),
        "version" => run.checkpoint_version,
        "fingerprint" => fingerprint(run),
        "state" => encoded,
        "budget" => budget,
        "usage" => Alto.Protocol.encode_term(Alto.Usage.to_map(saved.usage)),
        "agent_identity" => Alto.Protocol.encode_term(saved.agent_identity),
        "session_id" => run.session,
        "transcript_revision" => revision,
        "store" => store,
        "authority" => Alto.Protocol.encode_term(authority),
        "expires_at_ms" => expires
      }

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
         true <- packet["kind"] == "parent" and packet["stage"] in ["children", "frame"],
         true <- packet["version"] == run.checkpoint_version,
         true <- packet["fingerprint"] == fingerprint(run),
         {:ok, _} <- encode(packet),
         {:ok, store} <- OperationLog.identity(run.continuation_store, 100),
         true <- store == packet["store"],
         {:ok,
          %{
            run: saved,
            loop: loop,
            pending: pending,
            remaining: remaining,
            terminal: terminal,
            binding: binding
          } = decoded} <- decode(packet["state"]),
         true <- map_size(decoded) == 6,
         true <- valid_parent_binding?(binding, packet),
         :ok <- parent_budget_binding(run, packet["budget"]),
         true <- valid_parent_pending?(pending),
         true <- Atom.to_string(pending.kind) == packet["stage"],
         true <- valid_frame?(remaining, terminal),
         true <- valid_parent_saved?(saved, binding.authority),
         true <- valid_authority?(Map.take(run, @authority_fields)),
         authority <- narrow_authority(run, binding.authority),
         true <- saved.transcript_bytes <= authority.max_transcript_bytes,
         true <- saved.transcript_revision == packet["transcript_revision"],
         true <- packet["agent_identity"] == Alto.Protocol.encode_term(saved.agent_identity),
         true <- packet["usage"] == Alto.Protocol.encode_term(Alto.Usage.to_map(saved.usage)),
         true <- packet["session_id"] == run.session,
         {:ok, revision} <- transcript_revision(run),
         true <- revision == saved.transcript_revision,
         :ok <- unexpired(binding.expires_at_ms),
         {:ok, state} <- run.spec.driver.load_checkpoint(loop, run.spec),
         {:ok, budget} <- Budget.restore(opts, packet["budget"]),
         budget <- clamp_parent_deadline(budget, binding.expires_at_ms),
         :ok <- Budget.check(budget),
         true <- within_budget?(budget) do
      restored =
        run
        |> Map.merge(saved)
        |> Map.merge(authority)
        |> Map.put(:loop_state, state)
        |> Map.put(:budget, budget)
        |> Map.put(:parent_expires_at_ms, binding.expires_at_ms)
        |> Map.update!(:tool_context, &Map.put(&1, :agent_identity, saved.agent_identity))

      {:ok, restored, %{pending: pending, remaining: remaining, terminal: terminal}}
    else
      false -> {:error, :checkpoint_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_parent_checkpoint}
    end
  rescue
    _ -> {:error, :invalid_parent_checkpoint}
  catch
    :exit, _ -> {:error, :parent_checkpoint_store_unavailable}
  end

  def restore_parent(_, _, _), do: {:error, :invalid_parent_checkpoint}

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
      binding.store == packet["store"] and binding.budget == packet["budget"] and
      binding.session_id == packet["session_id"] and
      binding.expires_at_ms == packet["expires_at_ms"] and
      Alto.Protocol.encode_term(binding.authority) == packet["authority"]
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
      valid_agent_identity?(saved.agent_identity) and saved.agent_identity.path == [] and
      is_list(saved.messages_rev) and Enum.all?(saved.messages_rev, &is_map/1) and
      is_integer(saved.transcript_bytes) and saved.transcript_bytes >= 0 and
      saved.transcript_bytes <= authority.max_transcript_bytes and
      Alto.Context.Transcript.bytes(saved.messages_rev) == saved.transcript_bytes and
      is_integer(saved.transcript_revision) and saved.transcript_revision >= 0 and
      is_integer(saved.model_requests) and saved.model_requests >= 0 and
      is_integer(saved.op_seq) and saved.op_seq >= 0 and
      valid_usage?(saved.usage) and is_list(saved.persistence_errors) and
      is_boolean(saved.compacted?) and valid_pending_calls?(saved.pending_provider_calls) and
      (is_nil(saved.request_model_tools) or match?(%MapSet{}, saved.request_model_tools)) and
      saved.verdict in [:empty, :completed, :rejected_before_dispatch, :failed_known, :unknown]
  end

  defp valid_parent_saved?(_, _), do: false

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

  defp valid_parent_pending?(%{kind: :children, journal: journal, ids: ids} = pending) do
    map_size(pending) == 3 and valid_journal_identity?(journal) and
      is_list(ids) and length(ids) in 1..64 and length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1)))
  end

  defp valid_parent_pending?(_), do: false

  defp valid_journal_identity?(%{"key" => key, "generation" => generation} = identity) do
    map_size(identity) == 2 and is_binary(key) and byte_size(key) in 1..256 and
      String.valid?(key) and is_binary(generation) and
      String.match?(generation, ~r/\A[0-9a-f]{32}\z/)
  end

  defp valid_journal_identity?(_), do: false

  defp valid_frame?(remaining, terminal) do
    is_list(remaining) and
      Enum.all?(remaining, fn
        %Alto.Effect{kind: kind, data: data} ->
          kind in [:emit, :request_model, :run_tool, :invoke_tool, :spawn_agent, :spawn_agents] and
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

  defp valid_agent_identity?(%{root_run_id: root_run_id, path: path} = identity)
       when is_binary(root_run_id) and byte_size(root_run_id) in 1..256 and is_list(path) do
    map_size(identity) == 2 and length(path) <= 64 and
      String.valid?(root_run_id) and
      Enum.all?(path, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1)))
  end

  defp valid_agent_identity?(_), do: false

  defp fingerprint(run) do
    tools =
      Enum.map(run.tools, fn {name, tool} ->
        {name, tool.module, tool.module.module_info(:md5), tool.opts, tool.approval,
         tool.preparation}
      end)
      |> Enum.sort()

    data =
      {@continuation_format, run.spec.driver, run.spec.driver.module_info(:md5),
       run.spec.driver_options, run.spec.middleware, stable_subagents(run.spec.subagents), tools,
       run.model_tools, run.tool_context.cwd}

    :crypto.hash(:sha256, :erlang.term_to_binary(fingerprint_data(data)))
    |> Base.encode16(case: :lower)
  end

  # Fun ETF includes its creating process. Bind the code and closed-over
  # environment instead so trusted pure argument functions survive a new VM.
  defp fingerprint_data(value) when is_function(value) do
    Enum.map([:module, :name, :arity, :index, :uniq, :env], fn key ->
      {^key, data} = :erlang.fun_info(value, key)
      {key, fingerprint_data(data)}
    end)
  end

  defp fingerprint_data(%Alto.Subagents.Bounded{} = policy) do
    %{
      "kind" => "alto_subagents_bounded",
      "max_depth" => policy.max_depth,
      "max_children" => policy.max_children,
      "max_concurrency" => policy.max_concurrency,
      "sessions" => policy.sessions,
      "workspaces" => stable_resource(policy.workspaces),
      "journal" => stable_resource(policy.journal)
    }
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

  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= div(@limit * 4, 3) + 4 do
    case Codec.decode(encoded, max_bytes: @limit) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, :invalid_checkpoint_data}
    end
  rescue
    _ -> {:error, :invalid_checkpoint_data}
  end

  def decode(_), do: {:error, :invalid_checkpoint_data}

  defp stable_subagents(%Alto.Subagents.Bounded{} = policy), do: fingerprint_data(policy)
  defp stable_subagents(value), do: fingerprint_data(value)

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
    case OperationLog.identity(value, 100) do
      {:ok, identity} -> identity
      # Preserve an unavailable store reference in the digest. A restarted
      # or replaced store therefore cannot accidentally compare equal.
      _ -> value
    end
  end

  defp stable_resource(value), do: fingerprint_data(value)

  defp module_md5(module) when is_atom(module) do
    if Code.ensure_loaded?(module), do: module.module_info(:md5), else: :unavailable
  end

  defp module_md5(_), do: :unavailable
end
