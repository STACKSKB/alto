defmodule Alto.Runner.Execution.Workspace do
  @moduledoc "Optional resource setup and capture around an arbitrary worker callback."
  alias Alto.Runner.Budget
  @default_tool_timeout 125_000
  def execute(task, opts, manager, snapshot, identity, execute) do
    budget = Keyword.fetch!(opts, :budget)
    timeout = Keyword.get(opts, :tool_timeout, @default_tool_timeout)
    cancel_ref = Keyword.get(opts, :cancel_ref)

    with {:ok, ready} <-
           call(
             fn -> Alto.Workspaces.create(manager, snapshot, identity) end,
             budget,
             timeout,
             cancel_ref
           ),
         {:ok, outcome, worked} <-
           Alto.Workspaces.use(manager, ready.id, ready.revision, fn workspace ->
             execute.(task, Keyword.put(opts, :cwd, workspace["cwd"]))
           end) do
      finish(outcome, worked, opts, manager)
    else
      {:error, reason, outcome} ->
        workspace_failure(outcome, nil, reason)

      {:error, reason} ->
        {:error, {:workspace_failed, reason},
         %{empty_result() | verdict: :unknown, agent_identity: identity}}
    end
  end

  @doc "Reuse an existing worked workspace without preparing or creating it again."
  def resume(task, opts, manager, id, revision, execute) do
    Alto.Workspaces.resume(manager, id, revision, fn workspace ->
      execute.(task, Keyword.put(opts, :cwd, workspace["cwd"]))
    end)
    |> finish_resume(opts, manager)
  end

  @doc "Admit an already validated checkpoint before activating its retained workspace."
  def resume_checkpoint(opts, manager, id, revision, admit, execute) do
    Alto.Workspaces.resume(manager, id, revision, admit, execute)
    |> finish_resume(opts, manager)
  end

  defp finish_resume({:ok, outcome, worked}, opts, manager),
    do: finish(outcome, worked, opts, manager)

  defp finish_resume({:error, {:checkpoint_admission_failed, _}} = error, _, _), do: error

  defp finish_resume({:error, reason, outcome}, _, _),
    do: workspace_failure(outcome, nil, reason)

  defp finish_resume({:error, reason}, _, _),
    do: {:error, {:workspace_failed, reason}, %{empty_result() | verdict: :unknown}}

  defp finish({:error, :approval_suspended, _} = outcome, worked, _opts, _manager),
    do: attach_workspace(outcome, worked)

  defp finish(outcome, worked, opts, manager) do
    case call(
           fn -> Alto.Workspaces.freeze(manager, worked.id, worked.revision) end,
           Keyword.fetch!(opts, :budget),
           Keyword.get(opts, :tool_timeout, @default_tool_timeout),
           Keyword.get(opts, :cancel_ref)
         ) do
      {:ok, frozen} ->
        attach_workspace(outcome, frozen)

      {:error, reason} ->
        info =
          case Alto.Workspaces.get(manager, worked.id) do
            {:ok, current} -> current
            _ -> worked
          end

        workspace_failure(outcome, info, reason)
    end
  end

  def call(fun, budget, timeout, cancel_ref) do
    case Budget.check(budget) do
      :ok ->
        case supervised_call(fun, Budget.timeout(budget, timeout), cancel_ref) do
          {:ok, value} -> value
          {:error, reason} -> {:error, {:workspace_process_failed, reason}}
          {:cancelled, reason} -> {:error, {:cancelled, reason}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp attach_workspace({:ok, result}, info), do: {:ok, %{result | workspace: info}}

  defp attach_workspace({:error, reason, result}, info),
    do: {:error, reason, %{result | workspace: info}}

  defp workspace_failure(outcome, info, reason) do
    result = elem(outcome, tuple_size(outcome) - 1)
    {:error, {:workspace_failed, reason}, %{result | verdict: :unknown, workspace: info}}
  end

  defp supervised_call(fun, timeout, ref), do: Alto.Runner.Execution.Call.run(fun, timeout, ref)
  defp empty_result, do: Alto.Runner.Result.empty()
end
