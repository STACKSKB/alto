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
  @limit 1_000_000
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
    :compacted?
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
         "version" => run.checkpoint_version,
         "fingerprint" => fingerprint(run),
         "state" => encoded,
         "budget" => Budget.snapshot(run.budget),
         "usage" => Alto.Protocol.encode_term(Alto.Usage.to_map(run.usage)),
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

  def restore(run, %{"format" => 1} = packet, decision, opts) do
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
         {:ok, current_revision} <- transcript_revision(run),
         true <- current_revision == saved.transcript_revision,
         true <- within_budget?(budget) do
      restored =
        run |> Map.merge(saved) |> Map.put(:loop_state, state) |> Map.put(:budget, budget)

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

  defp fingerprint(run) do
    tools =
      Enum.map(run.tools, fn {name, tool} ->
        {name, tool.module, tool.module.module_info(:md5), tool.opts, tool.approval,
         tool.preparation}
      end)
      |> Enum.sort()

    data =
      {Alto.Runner.Serial.module_info(:md5), __MODULE__.module_info(:md5), run.spec.driver,
       run.spec.driver.module_info(:md5), run.spec.driver_options, run.spec.middleware,
       run.spec.subagents, tools, run.model_tools, run.tool_context.cwd}

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

  defp fingerprint_data(value) when is_map(value),
    do: Map.new(Map.to_list(value), fn {k, v} -> {fingerprint_data(k), fingerprint_data(v)} end)

  defp fingerprint_data(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&fingerprint_data/1) |> List.to_tuple()

  defp fingerprint_data(value) when is_list(value), do: Enum.map(value, &fingerprint_data/1)
  defp fingerprint_data(value), do: value

  def encode(term) do
    with true <- :erlang.external_size(term) <= @limit,
         true <- portable?(term, 0) do
      {:ok, Base.encode64(:erlang.term_to_binary(term))}
    else
      false -> {:error, :checkpoint_not_portable_or_too_large}
    end
  end

  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= div(@limit * 4, 3) + 4 do
    with {:ok, <<131, tag, _::binary>> = binary} when tag != 80 <- Base.decode64(encoded),
         true <- byte_size(binary) <= @limit,
         term <- :erlang.binary_to_term(binary, [:safe]),
         true <- portable?(term, 0) do
      {:ok, term}
    else
      _ -> {:error, :invalid_checkpoint_data}
    end
  rescue
    _ -> {:error, :invalid_checkpoint_data}
  end

  def decode(_), do: {:error, :invalid_checkpoint_data}

  defp portable?(_, depth) when depth > 64, do: false
  defp portable?(value, _) when is_atom(value) or is_binary(value) or is_number(value), do: true

  defp portable?(value, depth) when is_list(value),
    do: Enum.all?(value, &portable?(&1, depth + 1))

  defp portable?(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> portable?(depth + 1)

  defp portable?(value, depth) when is_map(value),
    do:
      Enum.all?(Map.to_list(value), fn {k, v} ->
        portable?(k, depth + 1) and portable?(v, depth + 1)
      end)

  defp portable?(_, _), do: false
end
