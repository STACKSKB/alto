defmodule Alto.Runner.Execution.Workspace do
  @moduledoc "Optional resource setup and capture around an arbitrary worker callback."
  alias Alto.Runner.{Budget, Result}
  @default_tool_timeout 125_000
  def execute(task, opts, manager, snapshot, identity, execute) do
    budget = Keyword.fetch!(opts, :budget)
    timeout = Keyword.get(opts, :tool_timeout, @default_tool_timeout)
    cancel_ref = Keyword.get(opts, :cancel_ref)

    with {:ok, ready} <-
           call(
             fn -> Alto.Resource.create(manager, snapshot, identity) end,
             budget,
             timeout,
             cancel_ref
           ) do
      Alto.Resource.use(manager, ready.id, ready.revision, fn workspace ->
        execute.(task, Keyword.put(opts, :cwd, workspace["cwd"]))
      end)
    end
    |> finish_work(opts, manager, identity)
  end

  @doc "Admit an already validated checkpoint before activating its retained workspace."
  def resume_checkpoint(opts, manager, id, revision, admit, execute) do
    Alto.Resource.resume(manager, id, revision, admit, execute)
    |> finish_work(opts, manager, nil)
  end

  defp finish_work({:ok, outcome, worked}, opts, manager, _identity),
    do: finish(outcome, worked, opts, manager)

  defp finish_work({:error, {:checkpoint_admission_failed, _}} = error, _, _, nil), do: error

  defp finish_work({:error, reason, outcome}, _, _, _),
    do: workspace_failure(outcome, nil, reason)

  defp finish_work({:error, reason}, _, _, identity),
    do:
      Result.error({:workspace_failed, reason}, %Result{
        verdict: :unknown,
        agent_identity: identity
      })

  defp finish(
         %Result{reason: :approval_suspended} = outcome,
         worked,
         _opts,
         _manager
       ),
       do: attach_workspace(outcome, worked)

  defp finish(outcome, worked, opts, manager) do
    case call(
           fn -> Alto.Resource.freeze(manager, worked.id, worked.revision) end,
           Keyword.fetch!(opts, :budget),
           Keyword.get(opts, :tool_timeout, @default_tool_timeout),
           Keyword.get(opts, :cancel_ref)
         ) do
      {:ok, frozen} ->
        attach_workspace(outcome, frozen)

      {:error, reason} ->
        info =
          case Alto.Resource.get(manager, worked.id) do
            {:ok, current} -> current
            _ -> worked
          end

        workspace_failure(outcome, info, reason)
    end
  end

  def call(fun, budget, timeout, cancel_ref) do
    with :ok <- Budget.check(budget) do
      Alto.Runner.Execution.Call.run(fun, Budget.timeout(budget, timeout), cancel_ref)
    end
  end

  defp attach_workspace(result, info), do: %{result | workspace: info}

  defp workspace_failure(result, info, reason),
    do: Result.error({:workspace_failed, reason}, %{result | verdict: :unknown, workspace: info})
end
