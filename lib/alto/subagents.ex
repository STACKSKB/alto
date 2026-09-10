defmodule Alto.Subagents do
  @moduledoc "Constructors for subagent policies."

  defmodule Bounded do
    @moduledoc false
    defstruct max_depth: 0, max_children: 16, max_concurrency: 1

    @type t :: %__MODULE__{
            max_depth: non_neg_integer(),
            max_children: pos_integer(),
            max_concurrency: pos_integer()
          }
  end

  @spec bounded(keyword()) :: Bounded.t()
  def bounded(opts \\ []) do
    opts = Keyword.validate!(opts, max_depth: 0, max_children: 16, max_concurrency: 1)
    max_depth = Keyword.fetch!(opts, :max_depth)

    if not is_integer(max_depth) or max_depth < 0 do
      raise ArgumentError, "max_depth must be a non-negative integer"
    end

    max_children = Keyword.fetch!(opts, :max_children)
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)

    unless is_integer(max_children) and max_children in 1..64 and
             is_integer(max_concurrency) and max_concurrency in 1..max_children do
      raise ArgumentError, "max_children must be 1..64 and max_concurrency 1..max_children"
    end

    %Bounded{max_depth: max_depth, max_children: max_children, max_concurrency: max_concurrency}
  end
end
