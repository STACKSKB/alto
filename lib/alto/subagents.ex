defmodule Alto.Subagents do
  @moduledoc "Built-in bounded subagent policy."
  @behaviour Alto.Subagents.Policy

  @impl true
  def limits(state), do: state
  @impl true
  def admit(_state, _agents, _context), do: :ok

  @spec bounded(keyword()) :: {module(), map()}
  def bounded(opts \\ []) do
    opts =
      NimbleOptions.validate!(opts,
        max_depth: [type: :non_neg_integer, default: 0],
        max_children: [type: {:in, 1..64}, default: 16],
        max_concurrency: [type: :pos_integer, default: 1],
        workspaces: [type: {:or, [nil, {:struct, Alto.Workspaces}]}, default: nil],
        sessions: [type: {:in, [:shared, :separate]}, default: :shared]
      )

    if opts[:max_concurrency] > opts[:max_children],
      do: raise(ArgumentError, "max_concurrency cannot exceed max_children")

    {__MODULE__, Map.new(opts)}
  end
end
