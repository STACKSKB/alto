defmodule Alto.Runner.Execution.Parent do
  @moduledoc "Durable parent batch boundaries shared by execution hosts."
  alias Alto.Runner.{Budget, Checkpoint}
  alias Alto.Runner.Execution.{Call, Children}
  alias Alto.Subagents.{Continuation, Journal}

  @doc "Resolve a saved continuation's session before assembling a fresh host."
  def options(opts) do
    if is_nil(Keyword.get(opts, :continuation)) do
      {:ok, opts}
    else
      timeout = Keyword.get(opts, :run_timeout, 30_000)

      if is_integer(timeout) and timeout > 0 do
        case Call.run(
               fn -> resolve_options(opts) end,
               min(timeout, 30_000),
               Keyword.get(opts, :cancel_ref)
             ) do
          {:ok, value} -> value
          {:cancelled, reason} -> {:error, {:cancelled, reason}}
          {:error, reason} -> {:error, {:continuation_store_unavailable, reason}}
        end
      else
        {:error, {:invalid_option, :run_timeout, timeout}}
      end
    end
  end

  defp resolve_options(opts) do
    case Keyword.get(opts, :continuation) do
      nil ->
        {:ok, opts}

      identity ->
        with store when not is_nil(store) <- Keyword.get(opts, :continuation_store),
             {:ok, cell} <- Continuation.restore(store, identity),
             {:ok, snapshot} <- Continuation.read(cell),
             true <- snapshot.phase in [:pending, :ready] do
          {:ok,
           opts
           |> Keyword.put(:session, snapshot.packet["session_id"])
           |> Keyword.put(:parent_transcript_revision, snapshot.packet["transcript_revision"])}
        else
          nil -> {:error, :continuation_store_required}
          false -> {:error, :continuation_already_claimed}
          {:error, _} = error -> error
        end
    end
  end

  def start(data, rest, terminal, run, complete) do
    with true <- run.agent_depth == 0 and not is_nil(run.subagent_journal),
         true <- is_struct(run.budget.account, Budget.Account),
         {:ok, specs, concurrency} <- Children.validate_batch(data, Children.project(run)),
         {:ok, specs, journal, state} <- Children.prepare_children(specs, Children.project(run)),
         run = Children.merge(run, state),
         pending = %{
           kind: :children,
           journal: Journal.identity(journal),
           ids: Enum.map(specs, & &1.id)
         },
         {:ok, packet} <-
           call(fn -> Checkpoint.capture_parent(run, pending, rest, terminal) end, run),
         run = Map.put(run, :parent_expires_at_ms, packet["expires_at_ms"]),
         metadata = %{
           "journal" => Journal.identity(journal),
           "host_key" => run.continuation_key,
           "parent_run_id" => run.tool_context.session_id,
           "parent_session_id" => run.session,
           "operation_seq" => run.op_seq
         },
         key = "parent:" <> Base.encode16(:crypto.hash(:sha256, journal.key), case: :lower),
         {:ok, cell} <-
           call(
             fn ->
               Continuation.open(run.continuation_store, key, packet, metadata,
                 deadline: run.budget.deadline
               )
             end,
             run
           ),
         {:ok, snapshot} <- call(fn -> Continuation.read(cell) end, run),
         true <- snapshot.phase == :pending do
      case Children.run_prepared_children(specs, concurrency, journal, Children.project(run)) do
        {:ok, :ok, _outcomes, _, state} ->
          join(cell, snapshot, journal, Children.merge(run, state), rest, terminal, complete)

        {:ok, {kind, reason}, outcomes, _, state} ->
          state =
            Enum.reduce(outcomes, state, fn {_, outcome}, acc ->
              Children.merge_child_result(acc, outcome)
            end)

          {kind, reason, Children.merge(run, state)}

        {:error, {:subagent_journal_failed, {:child_pending, _, _}}, _state} ->
          join(cell, snapshot, journal, run, rest, terminal, complete)

        {:error, reason, state} ->
          {:error, reason, Children.merge(run, state)}
      end
    else
      false -> {:error, :parent_continuation_not_supported, run}
      {:error, reason} -> {:error, reason, run}
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
         true <- snapshot.phase in [:pending, :ready],
         {:ok, restored, frame} <-
           call(fn -> Checkpoint.restore_parent(run, snapshot.packet, opts) end, run) do
      cell = %{cell | deadline: restored.budget.deadline}

      case {snapshot.phase, frame.pending} do
        {:pending, %{kind: :children, journal: binding, ids: ids}} ->
          with true <- binding == snapshot.metadata["journal"],
               {:ok, journal} <-
                 call(
                   fn ->
                     Journal.restore(restored.subagent_journal, binding,
                       deadline: restored.budget.deadline
                     )
                   end,
                   restored
                 ),
               {:ok, saved} <- call(fn -> Journal.read(journal) end, restored),
               true <- saved.packet["ids"] == ids,
               true <-
                 saved.packet["metadata"]["agent_identity"] ==
                   Alto.Protocol.encode_term(restored.agent_identity),
               :ok <- Children.resume_decided(journal, Children.project(restored)) do
            join(cell, snapshot, journal, restored, frame.remaining, frame.terminal, complete)
          else
            false -> {:error, :parent_journal_mismatch, restored}
            {:error, reason} -> {:error, reason, restored}
          end

        {:ready, %{kind: :frame}} ->
          grant(cell, snapshot, restored, frame.remaining, frame.terminal)

        _ ->
          {:error, :invalid_parent_continuation, restored}
      end
    else
      false -> {:error, :continuation_already_claimed, run}
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp join(cell, snapshot, journal, run, rest, terminal, complete) do
    case call(fn -> Journal.join(journal) end, run) do
      {:ok, joined} ->
        with {:ok, results, state} <-
               Children.merge_retained(joined.results, Children.project(run)),
             run = Children.merge(run, state),
             {:continue, frame, next_run} <- complete.(results, journal, run, rest, terminal),
             {:ok, packet} <-
               call(
                 fn ->
                   Checkpoint.capture_parent(
                     next_run,
                     %{kind: :frame},
                     frame.effects,
                     frame.terminal
                   )
                 end,
                 next_run
               ),
             {:ok, ready} <-
               call(fn -> Continuation.ready(cell, snapshot.revision, packet) end, next_run) do
          grant(cell, ready, next_run, frame.effects, frame.terminal)
        else
          {:done, outcome} -> {:done, outcome}
          {:error, reason} -> {:error, reason, run}
        end

      {:error, {:child_pending, _, _} = reason} ->
        {:suspended, reason, Continuation.identity(cell), run}

      {:error, reason} ->
        {:error, reason, run}
    end
  end

  defp grant(cell, snapshot, run, effects, terminal) do
    # The ready packet contains the exact consuming frame. Retain journal data
    # until this receipt is durable; neither a crash nor a failed CAS regrants it.
    with {:ok, journal} <-
           call(
             fn ->
               Journal.restore(run.subagent_journal, snapshot.metadata["journal"],
                 deadline: run.budget.deadline
               )
             end,
             run
           ),
         {:ok, joined} <- call(fn -> Journal.read(journal) end, run),
         receipt = %{
           "continuation" => Continuation.identity(cell),
           "ready_revision" => snapshot.revision
         },
         :ok <- acknowledge(journal, joined, receipt, run),
         :ok <- Budget.check(run.budget),
         {:ok, _claimed} <- call(fn -> Continuation.claim(cell, snapshot.revision) end, run) do
      {:continue, %Alto.Runner.Execution.Frame{effects: effects, terminal: terminal}, run}
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp acknowledge(journal, %{packet: %{"join" => nil}, revision: revision}, receipt, run) do
    case call(fn -> Journal.acknowledge(journal, revision, receipt) end, run) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp acknowledge(_, %{packet: %{"join" => receipt}}, receipt, _), do: :ok
  defp acknowledge(_, _, _, _), do: {:error, :parent_join_receipt_mismatch}

  defp call(fun, run) do
    case Call.run(fun, Budget.remaining(run.budget), run.cancel_ref) do
      {:ok, value} -> value
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      {:error, reason} -> {:error, {:continuation_store_outcome_unknown, reason}}
    end
  end
end
