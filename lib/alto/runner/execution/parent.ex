defmodule Alto.Runner.Execution.Parent do
  @moduledoc "Durable parent batch boundaries shared by execution hosts."
  alias Alto.Runner.{Budget, Checkpoint}
  alias Alto.Runner.Execution.{Call, Children, History}
  alias Alto.Subagents.Continuation

  def options(opts) do
    case Keyword.get(opts, :continuation) do
      nil -> {:ok, opts}
      identity -> resolve_options(opts, identity)
    end
  end

  defp resolve_options(opts, identity) do
    timeout = Keyword.get(opts, :run_timeout, 30_000)

    if is_integer(timeout) and timeout > 0 do
      case Call.run(
             fn -> resolve_packet(opts, identity) end,
             min(timeout, 30_000),
             opts[:cancel_ref]
           ) do
        {:ok, value} -> value
        {:cancelled, reason} -> {:error, {:cancelled, reason}}
        {:error, reason} -> {:error, {:continuation_store_unavailable, reason}}
      end
    else
      {:error, {:invalid_option, :run_timeout, timeout}}
    end
  end

  defp resolve_packet(opts, identity) do
    with store when not is_nil(store) <- opts[:continuation_store],
         {:ok, cell} <- Continuation.restore(store, identity),
         {:ok, snapshot} <- Continuation.read(cell),
         {:ok, packet} <- parent_packet(snapshot) do
      {:ok,
       opts
       |> Keyword.put(:session, packet["session_id"])
       |> Keyword.put(:parent_transcript_revision, packet["transcript_revision"])}
    else
      nil -> {:error, :continuation_store_required}
      {:error, _} = error -> error
    end
  end

  def start(data, rest, terminal, run, complete) do
    with true <- run.agent_depth == 0 and not is_nil(run.continuation_store),
         true <- is_struct(run.budget.account, Budget.Account),
         {:ok, specs, concurrency} <- Children.validate_batch(data, run),
         {:ok, specs} <- Children.prepare_resources(specs, run),
         {key, run} <- Children.reserve_continuation(run),
         {:ok, run} <- History.persist(run, allow_pending: true),
         pending = %{kind: :children, ids: Enum.map(specs, & &1.id)},
         {:ok, packet} <-
           call(fn -> Checkpoint.capture_parent(run, pending, rest, terminal) end, run),
         run = Map.put(run, :parent_expires_at_ms, packet["expires_at_ms"]),
         {:ok, cell, run} <-
           Children.open_reserved_continuation(specs, run, packet, key),
         {:ok, %{phase: :children}} <- call(fn -> Continuation.read(cell) end, run) do
      case Children.run_prepared_children(specs, concurrency, cell, run) do
        {:ok, :ok, _, _, state} ->
          join(cell, state, rest, terminal, complete)

        {:ok, {kind, reason}, outcomes, _, state} ->
          state =
            Enum.reduce(outcomes, state, fn {_, out}, acc ->
              Children.merge_child_result(acc, out)
            end)

          {kind, reason, state}

        {:error, {:subagent_journal_failed, {:child_pending, _, _}}, _} ->
          join(cell, run, rest, terminal, complete)

        {:error, reason, state} ->
          {:error, reason, state}
      end
    else
      false -> {:error, :parent_continuation_not_supported, run}
      {:cancelled, reason} -> {:cancelled, reason, run}
      {:error, reason} -> {:error, reason, run}
      {:error, reason, failed} -> {:error, reason, failed}
    end
  end

  def resume(run, identity, opts, complete) do
    with {:ok, cell} <-
           call(
             fn ->
               Continuation.restore(run.continuation_store, identity,
                 deadline: run.budget.deadline
               )
             end,
             run
           ),
         {:ok, snapshot} <- call(fn -> Continuation.read(cell) end, run),
         {:ok, packet} <- parent_packet(snapshot),
         {:ok, restored, frame} <-
           call(fn -> Checkpoint.restore_parent(run, packet, opts) end, run) do
      cell = %{cell | deadline: restored.budget.deadline}

      case {snapshot.phase, frame.pending} do
        {:children, %{kind: :children, ids: ids}} ->
          with true <- snapshot.ids == ids,
               true <-
                 snapshot.metadata["agent_identity"] ==
                   Alto.Protocol.encode_term(restored.agent_identity),
               :ok <- Children.resume_decided(cell, restored) do
            join(cell, restored, frame.remaining, frame.terminal, complete)
          else
            false -> {:error, :parent_continuation_mismatch, restored}
            {:cancelled, reason} -> {:cancelled, reason, restored}
            {:error, reason} -> {:error, reason, restored}
          end

        {:ready, %{kind: :frame}} ->
          grant(cell, snapshot, restored, frame.remaining, frame.terminal)

        _ ->
          {:error, :invalid_parent_continuation, restored}
      end
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp join(cell, run, rest, terminal, complete) do
    case call(fn -> Continuation.join(cell) end, run) do
      {:ok, joined} ->
        with {:ok, results, run} <- Children.merge_retained(joined.results, run),
             {:continue, frame, next} <- complete.(results, cell, run, rest, terminal),
             {:ok, next} <- History.persist(next, allow_pending: true),
             {:ok, packet} <-
               call(
                 fn ->
                   Checkpoint.capture_parent(next, %{kind: :frame}, frame.effects, frame.terminal)
                 end,
                 next
               ),
             {:ok, ready} <-
               call(fn -> Continuation.ready(cell, joined.revision, packet) end, next) do
          grant(cell, ready, next, frame.effects, frame.terminal)
        else
          {:done, outcome} -> {:done, outcome}
          {:error, reason} -> {:error, reason, run}
          {:error, reason, failed} -> {:error, reason, failed}
        end

      {:error, {:child_pending, _, _} = reason} ->
        {:suspended, reason, Continuation.identity(cell), run}

      {:error, reason} ->
        {:error, reason, run}
    end
  end

  defp grant(cell, snapshot, run, effects, terminal) do
    with :ok <- Budget.check(run.budget),
         {:ok, _} <- call(fn -> Continuation.claim(cell, snapshot.revision) end, run) do
      {:continue, %Alto.Runner.Execution.Frame{effects: effects, terminal: terminal}, run}
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp parent_packet(%{phase: :children, parent: packet}) when is_map(packet), do: {:ok, packet}
  defp parent_packet(%{phase: :ready, packet: %{"packet" => packet}}), do: {:ok, packet}
  defp parent_packet(%{phase: :claimed}), do: {:error, :continuation_already_claimed}
  defp parent_packet(_), do: {:error, :invalid_parent_continuation}

  defp call(fun, run) do
    case Call.run(fun, Budget.remaining(run.budget), run.cancel_ref) do
      {:ok, value} -> value
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      {:error, reason} -> {:error, {:continuation_store_outcome_unknown, reason}}
    end
  end
end
