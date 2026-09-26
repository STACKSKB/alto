defmodule Alto.Subagents do
  @moduledoc "Built-in bounded subagent policy."
  @spec bounded(keyword()) :: map()
  def bounded(opts \\ []) do
    opts =
      NimbleOptions.validate!(opts,
        admit: [type: {:fun, 2}, default: fn _, _ -> :ok end],
        max_depth: [type: :non_neg_integer, default: 0],
        max_children: [type: {:in, 1..64}, default: 16],
        max_concurrency: [type: :pos_integer, default: 1],
        workspaces: [type: {:or, [nil, {:struct, Alto.Workspaces}]}, default: nil],
        sessions: [type: {:in, [:shared, :separate]}, default: :shared]
      )

    if opts[:max_concurrency] > opts[:max_children],
      do: raise(ArgumentError, "max_concurrency cannot exceed max_children")

    Map.new(opts)
  end
end
