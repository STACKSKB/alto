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
