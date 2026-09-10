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
      case call(
             fn -> Alto.Workspaces.freeze(manager, worked.id, worked.revision) end,
             budget,
             timeout,
             cancel_ref
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
    else
      {:error, reason, outcome} ->
        workspace_failure(outcome, nil, reason)

      {:error, reason} ->
        {:error, {:workspace_failed, reason},
         %{empty_result() | verdict: :unknown, agent_identity: identity}}
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
