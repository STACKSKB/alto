defmodule Alto.Contrib.Resident.Lifecycle do
  @moduledoc "Explicit terminal-task cleanup with a durable, restartable retirement plan."
  alias Alto.OperationLog
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.Continuation
  alias Alto.Persistence.Retained
  alias Alto.Contrib.Resident.{Config, ParentRuns, Service}

  @tool "alto_resident_task_cleanup"
  @attempt "retire-resources"

  def ledger(name \\ Service), do: Service.component(name, :cleanup)

  def child(config, name) do
    Supervisor.child_spec(
      {OperationLog,
       name: ledger(name),
       id: "task-cleanup",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: config.scheduling[:max_tasks],
       max_recovery_bytes: 1_000_000,
       max_record_bytes: 2_000_000},
      id: __MODULE__
    )
  end

  # Tasks serializes admission/reconciliation and establishes terminality first.
  # The complete plan is durable before any component becomes evictable.
  def cleanup(config, name, recovered) do
    payload = recovered.recovery[:payload]
    generation = recovered.recovery[:generation_id]
    key = payload["id"] <> ":" <> generation

    with {:ok, opts} <- Config.resolve(config, payload["profile"]),
         {:ok, binding} <- ParentRuns.store_binding(opts),
         true <- binding == payload["parent_store"],
         {:ok, stores} <- stores(opts, name),
         {:ok, entry} <-
           plan(ledger(name), key, payload, generation, recovered.revision, stores, opts),
         :ok <- execute(ledger(name), key, entry, stores) do
      cleaned(payload["id"], entry)
    else
      false -> {:error, :parent_recovery_configuration_mismatch}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  @doc "Finish a previously planned cleanup after its terminal task record was evicted."
  def resume(config, name, id, task_revision)
      when is_binary(id) and is_integer(task_revision) and task_revision > 0 do
    with {:ok, key, entry} <- find_plan(ledger(name), id, task_revision),
         {:ok, opts} <- Config.resolve(config, entry.recovery["profile"]),
         {:ok, binding} <- ParentRuns.store_binding(opts),
         true <- binding == entry.recovery["parent_store"],
         {:ok, stores} <- stores(opts, name),
         true <- store_bindings(stores) == entry.recovery["stores"],
         :ok <- execute(ledger(name), key, entry, stores) do
      cleaned(id, entry)
    else
      false -> {:error, :cleanup_plan_mismatch}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  def resume(_, _, _, _), do: {:error, :invalid_cleanup_request}

  @doc "Deny task id reuse while its cleanup, owned budget, or selected parent store retains state."
  def available?(config, name, %{"id" => id, "profile" => profile}) do
    with {:ok, opts} <- Config.resolve(config, profile),
         :ok <- unreserved_cell(ParentRuns.budgets(name), "task:" <> id, Account),
         :ok <- unreserved_cleanup(ledger(name), id),
         :ok <- unreserved_cell(ParentRuns.bindings(name), id, ParentRuns),
         :ok <- unreserved_parent(Keyword.get(opts, :continuation_store), id, name) do
      :ok
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  def available?(_, _, _), do: {:error, :invalid_cleanup_request}

  defp cleaned(id, entry) do
    {:ok, %{task_id: id, status: "cleaned", resources: length(entry.recovery["resources"])}}
  end

  defp find_plan(ledger, id, task_revision) do
    matches =
      for %{
            operation_key: key,
            tool: @tool,
            recovery: %{"task" => ^id, "task_revision" => ^task_revision}
          } = entry <- OperationLog.request(ledger, {:entries, :all}),
          String.starts_with?(key, id <> ":"),
          do: {key, entry}

    case matches do
      [{key, entry}] -> {:ok, key, entry}
      [] -> {:error, :cleanup_plan_not_found}
      _ -> {:error, :ambiguous_cleanup_plan}
    end
  end

  defp unreserved_cleanup(ledger, id) do
    if Enum.any?(
         OperationLog.request(ledger, {:entries, :all}),
         &String.starts_with?(&1.operation_key, id <> ":")
       ),
       do: {:error, :task_id_retained},
       else: :ok
  end

  defp unreserved_cell(server, key, kind) do
    case Retained.lookup(server, key, kind) do
      {:error, :not_found} -> :ok
      {:ok, _, _} -> {:error, :task_id_retained}
      error -> error
    end
  end

  defp unreserved_parent(nil, _id, _name), do: :ok

  defp unreserved_parent(server, id, name) do
    case ParentRuns.continuations(server, id, name) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :task_id_retained}
      error -> error
    end
  end

  defp stores(opts, name) do
    servers = %{"budget" => ParentRuns.budgets(name)}

    servers =
      case Keyword.get(opts, :continuation_store) do
        nil ->
          servers

        store ->
          servers |> Map.put("parent", store) |> Map.put("binding", ParentRuns.bindings(name))
      end

    Alto.Result.reduce(servers, %{}, fn {role, server}, acc ->
      with {:ok, identity} <- OperationLog.request(server, :identity),
           do: {:ok, Map.put(acc, role, %{server: server, identity: identity})}
    end)
  end

  defp plan(ledger, key, payload, generation, task_revision, stores, opts) do
    task = payload["id"]

    identity = %{
      "task" => task,
      "generation" => generation,
      "task_revision" => task_revision,
      "profile" => payload["profile"],
      "parent_store" => payload["parent_store"],
      "stores" => store_bindings(stores)
    }

    case OperationLog.request(ledger, {:recovery, key}) do
      {:ok, %{tool: @tool, recovery: recovery} = entry} when is_map(recovery) ->
        if Map.take(recovery, Map.keys(identity)) === identity,
          do: {:ok, entry},
          else: {:error, :cleanup_plan_mismatch}

      {:ok, _} ->
        {:error, :cleanup_plan_mismatch}

      {:error, :not_found} ->
        with {:ok, resources} <- resources(task, stores, opts),
             :ok <-
               OperationLog.request(
                 ledger,
                 {:intent, key, @tool, nil, Map.put(identity, "resources", resources)}
               ) do
          OperationLog.request(ledger, {:recovery, key})
        end

      error ->
        error
    end
  end

  defp store_bindings(stores),
    do: Map.new(stores, fn {role, store} -> {role, store.identity} end)

  defp resources(task, stores, opts) do
    with {:ok, cells} <-
           parent_resources(task, stores, is_nil(Keyword.get(opts, :budget_account))),
         {:ok, accounts} <- owned_account(task, cells, stores, opts),
         {:ok, bindings} <- binding_resource(task, stores) do
      {:ok, Enum.map(cells, & &1.cell) ++ accounts ++ bindings}
    end
  end

  defp parent_resources(_task, stores, _task_owned_budget?) when not is_map_key(stores, "parent"),
    do: {:ok, []}

  defp parent_resources(task, stores, task_owned_budget?) do
    parent = stores["parent"].server

    with {:ok, listed} <-
           ParentRuns.select_continuations(
             parent,
             task,
             stores["binding"].server,
             stores["budget"].server,
             task_owned_budget?
           ) do
      Alto.Result.traverse(listed, fn %{identity: identity, snapshot: snapshot, parent_data: data} ->
        if snapshot.phase == :claimed,
          do:
            {:ok,
             %{cell: resource("parent", identity, snapshot), account: data.budget["account"]}},
          else: {:error, :unconsumed_parent_resources}
      end)
    end
  end

  defp binding_resource(_task, stores) when not is_map_key(stores, "binding"), do: {:ok, []}

  defp binding_resource(task, stores) do
    case Retained.lookup(stores["binding"].server, task, ParentRuns) do
      {:ok, cell, snapshot} -> {:ok, [resource("binding", Retained.identity(cell), snapshot)]}
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  defp owned_account(task, cells, stores, opts) do
    # An explicitly supplied profile account may span tasks and belongs to its host.
    case Keyword.get(opts, :budget_account) do
      %Retained{kind: Account} -> {:ok, []}
      nil -> owned_task_account(task, cells, stores)
      _ -> {:error, :invalid_task_budget_account}
    end
  end

  defp owned_task_account(task, cells, stores) do
    key = "task:" <> task

    accounts = Enum.uniq(Enum.map(cells, & &1.account))

    if accounts == [] or match?([%{"key" => ^key}], accounts) do
      case Account.lookup(stores["budget"].server, key) do
        {:ok, account, snapshot} ->
          binding = Account.identity(account)

          if accounts == [] or binding in accounts,
            do: {:ok, [resource("budget", binding, snapshot)]},
            else: {:error, :budget_account_mismatch}

        {:error, :not_found} when accounts == [] ->
          {:ok, []}

        error ->
          error
      end
    else
      {:error, :task_budget_ownership_mismatch}
    end
  end

  defp execute(_, _, %{status: {:decided, :completed, _}}, _), do: :ok

  defp execute(ledger, key, entry, stores) do
    with :ok <- OperationLog.request(ledger, {:attempt, key, @attempt}),
         :ok <- Alto.Result.each(entry.recovery["resources"], &retire(&1, stores)),
         :ok <-
           OperationLog.request(
             ledger,
             {:outcome, key, @attempt, :completed,
              %{
                resources: length(entry.recovery["resources"])
              }}
           ) do
      :ok
    end
  end

  defp retire(resource, stores) do
    server = stores[resource["role"]].server
    binding = resource["identity"]
    # Only terminal records can be evicted or replaced. The saved cleanup intent
    # authorizes finishing that original generation, never touching its successor.
    case lookup_resource(resource["role"], server, binding["key"]) do
      {:error, :not_found} ->
        :ok

      {:ok, handle, snapshot} ->
        if Retained.identity(handle)["generation"] != binding["generation"] do
          :ok
        else
          retire_existing(resource, handle, snapshot)
        end

      error ->
        error
    end
  end

  defp lookup_resource("budget", server, key), do: Account.lookup(server, key)
  defp lookup_resource("parent", server, key), do: Continuation.lookup(server, key)
  defp lookup_resource("binding", server, key), do: Retained.lookup(server, key, ParentRuns)

  defp retire_existing(%{"role" => role, "revision" => revision}, handle, snapshot) do
    {module, method} =
      case role do
        "budget" -> {Account, :close}
        "parent" -> {Continuation, :retire}
        "binding" -> {Retained, :retire}
      end

    if snapshot.state != :active or snapshot.revision == revision,
      do: apply(module, method, [handle, snapshot.revision]),
      else: {:error, :stale_cleanup_resource}
  end

  defp resource(role, binding, snapshot),
    do: %{"role" => role, "identity" => binding, "revision" => snapshot.revision}
end
