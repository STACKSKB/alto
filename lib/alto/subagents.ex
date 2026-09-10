defmodule Alto.Subagents do
  @moduledoc "Constructors for subagent policies."

  defmodule Bounded do
    @moduledoc false
    defstruct max_depth: 0

    @type t :: %__MODULE__{max_depth: non_neg_integer()}
  end

  @spec bounded(keyword()) :: Bounded.t()
  def bounded(opts \\ []) do
    opts = Keyword.validate!(opts, max_depth: 0)
    max_depth = Keyword.fetch!(opts, :max_depth)

    if not is_integer(max_depth) or max_depth < 0 do
      raise ArgumentError, "max_depth must be a non-negative integer"
    end

    %Bounded{max_depth: max_depth}
  end
end
