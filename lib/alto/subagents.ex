defmodule Alto.Subagents do
  @moduledoc "Constructors for subagent policies."

  defmodule Bounded do
    @moduledoc false
    @behaviour Alto.Subagents.Policy
    @impl true
    def limits(state), do: Map.from_struct(state)
    @impl true
    def admit(_state, _agents, _context), do: :ok

    defstruct max_depth: 0,
              max_children: 16,
              max_concurrency: 1,
              workspaces: nil,
              sessions: :shared

    @type t :: %__MODULE__{
            max_depth: non_neg_integer(),
            max_children: pos_integer(),
            max_concurrency: pos_integer(),
            workspaces: Alto.Workspaces.t() | nil,
            sessions: :shared | :separate
          }
  end

  @spec bounded(keyword()) :: Bounded.t()
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

    struct!(Bounded, opts)
  end
end
