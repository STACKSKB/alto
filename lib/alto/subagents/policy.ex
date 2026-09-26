defmodule Alto.Subagents.Policy do
  @moduledoc """
  Replaceable child admission policy. Implementations supply deterministic
  limits and may reject a batch. Execution independently enforces these limits,
  inherited authority, identity, shared budgets and durable dispatch.
  Policies are `{module, state}` values composed by the host.
  """
  @callback limits(term()) :: map()
  @callback admit(term(), [map()], map()) :: :ok | {:error, term()}

  @schema [
    max_depth: [type: :non_neg_integer, required: true],
    max_children: [type: :pos_integer, required: true],
    max_concurrency: [type: :pos_integer, required: true],
    sessions: [type: {:in, [:shared, :separate]}, default: :shared],
    workspaces: [type: :any, default: nil]
  ]

  def implementation?(module), do: Alto.Capabilities.implements?(module, __MODULE__)

  def validate(policy) do
    with {:ok, _limits} <- resolve(policy), do: :ok
  end

  def resolve(policy) do
    {:ok, limits!(policy)}
  catch
    _, _ -> {:error, :invalid_subagent_policy}
  end

  def limits!(nil),
    do: %{
      max_depth: 0,
      max_children: 1,
      max_concurrency: 1,
      sessions: :shared,
      workspaces: nil
    }

  def limits!({module, state}) do
    true = implementation?(module)

    limits =
      module.limits(state) |> Map.to_list() |> NimbleOptions.validate!(@schema) |> Map.new()

    true = limits.max_children <= 64 and limits.max_concurrency <= limits.max_children
    limits
  end

  def admit(nil, _agents, _context), do: {:error, :invalid_subagent_policy}

  def admit({module, state}, agents, context) do
    case module.admit(state, agents, context) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_subagent_policy_result}
    end
  end

  @doc "Stable policy identity with host-normalized durable resource identities."
  def fingerprint({module, state} = policy, resource) do
    limits = limits!(policy)

    state =
      cond do
        is_map(state) ->
          Map.delete(state, :workspaces)

        is_list(state) ->
          if Keyword.keyword?(state),
            do: Keyword.delete(state, :workspaces),
            else: state

        true ->
          state
      end

    limits = Map.update!(limits, :workspaces, resource)
    %{module: module, code: module.module_info(:md5), state: state, limits: limits}
  end
end
