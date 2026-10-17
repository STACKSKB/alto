defmodule Alto.Contrib.Resident.ParentRuns do
  @moduledoc "Resident parent recovery selection and per-task shared budget policy."
  alias Alto.{OperationLog, Subagents.Continuation}
  alias Alto.Persistence.Retained
  alias Alto.Runner.Checkpoint
  alias Alto.Runner.Budget.Account
  alias Alto.Contrib.Resident.{Config, Service}

  def ledger(name \\ Service), do: Service.component(name, :parent_runs)
  def budgets(name \\ Service), do: Service.component(name, :task_budgets)

  def bindings(name \\ Service), do: Service.component(name, :parent_bindings)

  def children(config, name) do
    # Parent frames need the checkpoint envelope; larger child retention limits
    # also apply to the aggregate packet.
    parent_bytes = max(3_000_000, config.child_runs[:max_batch_bytes])
    task_limit = config.scheduling[:max_tasks]

    Enum.map(
      [
        {ledger(name), "parent-continuations", config.child_runs[:max_retained], parent_bytes},
        {budgets(name), "task-budgets", task_limit, 3_000_000},
        {bindings(name), "parent-bindings", task_limit, 3_000_000}
      ],
      fn {server, id, limit, envelope_bytes} ->
        Supervisor.child_spec(
          {OperationLog,
           name: server,
           id: id,
           dir: Path.join(config.state_dir, "operations"),
           max_ops: limit,
           max_log_bytes: config.child_runs[:max_log_bytes],
           max_recovery_bytes: envelope_bytes,
           max_record_bytes: envelope_bytes * 2},
          id: {__MODULE__, id}
        )
      end
    )
  end

  def options(opts, name, payload, approval_resume?) when is_list(opts) do
    with :ok <- matches_binding(opts, payload["parent_store"]) do
      case Keyword.get(opts, :continuation_store) do
        nil ->
          {:ok, []}

        store ->
          with {:ok, account} <- account(opts, name, payload["id"]),
               {:ok, candidate} <-
                 latest(store, payload["id"], name, is_nil(Keyword.get(opts, :budget_account))) do
            extra = [budget_account: account]

            if approval_resume? or is_nil(candidate),
              do: {:ok, extra},
              else: {:ok, Keyword.put(extra, :continuation, candidate.identity)}
          end
      end
    end
  end

  def inspect_task(config, profile, id, binding \\ nil, name \\ Service) do
    with {:ok, _store, candidate} <- candidate(config, profile, id, binding, name) do
      candidate
    else
      nil -> nil
      {:error, reason} -> %{state: "unavailable", reason: reason}
    end
  catch
    :exit, reason -> %{state: "unavailable", reason: {:parent_store_unavailable, reason}}
  end

  def recoverable(config, profile, id, requested, binding, name \\ Service) do
    with {:ok, store, candidate} when not is_nil(candidate) <-
           candidate(config, profile, id, binding, name),
         true <-
           requested["key"] == candidate.identity["key"] and
             requested["generation"] == candidate.identity["generation"] and
             requested["continuation_revision"] == candidate.revision,
         true <- candidate.phase in [:children, :ready],
         {:ok, cell} <- Continuation.restore(store, candidate.identity),
         {:ok, snapshot} <- Continuation.read(cell),
         :ok <- completed_children(snapshot) do
      :ok
    else
      false -> {:error, :stale_or_claimed_parent_continuation}
      nil -> {:error, :parent_recovery_not_enabled}
      {:ok, _, nil} -> {:error, :parent_continuation_not_found}
      {:error, _} = error -> error
    end
  end

  def decide_child(config, payload, requested, name \\ Service) do
    with {:ok, store, candidate} when not is_nil(candidate) <-
           candidate(config, payload["profile"], payload["id"], payload["parent_store"], name),
         true <- candidate.phase == :children,
         {:ok, cell} <-
           Continuation.restore(store, candidate.identity),
         binding = %{"key" => requested["key"], "generation" => requested["generation"]},
         true <- binding == candidate.identity,
         identity = %{
           "journal" => binding,
           "id" => requested["child"],
           "attempt" => requested["attempt"],
           "suspension" => requested["suspension"]
         },
         decision when decision in [:approve, :deny] <-
           %{"approve" => :approve, "deny" => :deny}[requested["decision"]],
         {:ok, decided} <-
           Continuation.decide(cell, requested["batch_revision"], identity, decision) do
      {:ok,
       %{
         "key" => candidate.identity["key"],
         "generation" => candidate.identity["generation"],
         "continuation_revision" => decided.revision
       }}
    else
      false -> {:error, :stale_or_mismatched_child_continuation}
      {:ok, _, nil} -> {:error, :parent_continuation_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_child_decision}
    end
  end

  defp candidate(config, profile, id, binding, name) do
    with {:ok, opts} <- Config.resolve(config, profile),
         :ok <- matches_binding(opts, binding),
         store when not is_nil(store) <- Keyword.get(opts, :continuation_store),
         {:ok, candidate} <- latest(store, id, name, is_nil(Keyword.get(opts, :budget_account))),
         do: {:ok, store, candidate}
  end

  def store_binding(opts) do
    case Keyword.get(opts, :continuation_store) do
      nil -> {:ok, nil}
      store -> OperationLog.request(store, :identity)
    end
  catch
    :exit, reason -> {:error, {:parent_store_unavailable, reason}}
  end

  defp matches_binding(opts, expected) do
    with {:ok, actual} <- store_binding(opts) do
      if actual == expected, do: :ok, else: {:error, :parent_recovery_configuration_mismatch}
    end
  end

  defp completed_children(%{phase: :ready}), do: :ok

  defp completed_children(snapshot) do
    children = snapshot.packet["children"]

    if Enum.any?(Map.values(children), &match?({:decided, _, _, _, _}, &1)) do
      :ok
    else
      case Enum.find(snapshot.ids, &(elem(children[&1], 0) != :completed)) do
        nil -> :ok
        id -> {:error, {:child_pending, id, Atom.to_string(elem(children[id], 0))}}
      end
    end
  end

  defp account(opts, name, id) do
    case Keyword.get(opts, :budget_account) do
      nil ->
        Account.open(budgets(name), "task:" <> id,
          max_effects: Keyword.fetch!(opts, :max_effects),
          max_model_requests: Keyword.fetch!(opts, :max_model_requests)
        )

      %Retained{kind: Account} = account ->
        {:ok, account}

      _ ->
        {:error, :invalid_task_budget_account}
    end
  end

  @doc "Persist task ownership of a registry run before acknowledging its start."
  def record_run(name, id, run_id) do
    with {:ok, cell, _} <-
           Retained.open(bindings(name), id, __MODULE__, %{"task" => id}, %{"run_ids" => []}),
         {:ok, _} <-
           Retained.update(cell, fn snapshot ->
             {:ok, %{"run_ids" => Enum.uniq(snapshot.packet["run_ids"] ++ [run_id])}}
           end) do
      :ok
    end
  end

  @doc false
  def snapshot(
        %{initial: %{"task" => task} = initial, packet: %{"run_ids" => ids} = packet} = snapshot
      )
      when is_binary(task) and is_list(ids) and map_size(initial) == 1 and map_size(packet) == 1 do
    if length(ids) <= 128 and ids == Enum.uniq(ids) and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)),
       do: {:ok, snapshot},
       else: {:error, :invalid_parent_binding}
  end

  def snapshot(_), do: {:error, :invalid_parent_binding}

  @doc "List the parent aggregates attributable to one task."
  def continuations(store, id, name \\ Service),
    do: select_continuations(store, id, bindings(name), budgets(name))

  @doc false
  def select_continuations(store, id, binding_server, budget_server, task_owned_budget? \\ true) do
    with {:ok, runs} <- associated_runs(binding_server, id),
         {:ok, account} <- owned_account_identity(budget_server, id),
         {:ok, store_identity} <- OperationLog.request(store, :identity),
         {:ok, entries} <- Continuation.list(store) do
      Alto.Result.traverse(entries, fn %{snapshot: snapshot} = entry ->
        case parent_data(snapshot, store_identity) do
          {:ok, data} ->
            owned? =
              task_owned_budget? and runs == [] and not is_nil(account) and
                data.budget["account"] == account

            associated? = snapshot.metadata["parent_run_id"] in runs
            {:ok, if(owned? or associated?, do: Map.put(entry, :parent_data, data))}

          {:error, _} = error ->
            error

          nil ->
            {:ok, nil}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reject(entries, &is_nil/1)}
        error -> error
      end
    end
  end

  defp associated_runs(server, id) do
    case Retained.lookup(server, id, __MODULE__) do
      {:ok, _, snapshot} -> {:ok, snapshot.packet["run_ids"]}
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  defp owned_account_identity(server, id) do
    case Account.lookup(server, "task:" <> id) do
      {:ok, account, _} -> {:ok, Account.identity(account)}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp parent_data(%{parent: nil}, _store_identity), do: nil

  defp parent_data(
         %{parent: %{"kind" => "parent", "continuation_format" => 4, "state" => encoded}},
         store_identity
       ) do
    with {:ok,
          %{
            budget: %{"account" => account},
            run: %{op_seq: sequence},
            binding: %{store: ^store_identity}
          } = data} <- Checkpoint.decode(encoded),
         true <- is_map(account) and is_integer(sequence) and sequence >= 0 do
      {:ok, data}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_parent_checkpoint}
    end
  end

  defp parent_data(_, _), do: {:error, :invalid_parent_checkpoint}

  defp latest(store, id, name, task_owned_budget?) do
    with {:ok, entries} <-
           select_continuations(store, id, bindings(name), budgets(name), task_owned_budget?) do
      values =
        Enum.map(entries, fn %{identity: identity, snapshot: snapshot, parent_data: data} ->
          %{
            identity: identity,
            revision: snapshot.revision,
            phase: snapshot.phase,
            operation_seq: data.run.op_seq,
            session_id: snapshot.metadata["parent_session_id"]
          }
        end)

      {:ok, Enum.max_by(values, & &1.operation_seq, fn -> nil end)}
    end
  catch
    :exit, reason -> {:error, {:parent_store_unavailable, reason}}
  end
end
