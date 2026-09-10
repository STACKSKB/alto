defmodule Alto.Loop.Spec do
  @moduledoc "A complete, composable description of an Alto control loop."

  @enforce_keys [:driver]
  defstruct [:driver, :context, :subagents, driver_options: [], middleware: []]

  @type middleware :: module() | {module(), keyword()}
  @type t :: %__MODULE__{
          driver: module(),
          context: term(),
          subagents: term(),
          driver_options: keyword(),
          middleware: [middleware()]
        }

  @spec new(module(), keyword()) :: t()
  def new(driver, opts \\ []) when is_atom(driver) do
    {known, driver_options} =
      Keyword.split(opts, [:context, :subagents, :middleware, :driver_options])

    %__MODULE__{
      driver: driver,
      context: Keyword.get(known, :context),
      subagents: Keyword.get(known, :subagents),
      middleware: Keyword.get(known, :middleware, []),
      # driver_options binds the values Keyword.split extracted for the
      # :driver_options key, while the unrecognized rest of opts lands here
      # too: unknown options pass through to the driver on purpose.
      driver_options: Keyword.get(known, :driver_options, []) ++ driver_options
    }
  end

  @spec add_middleware(t(), middleware()) :: t()
  def add_middleware(%__MODULE__{} = spec, middleware) do
    %{spec | middleware: spec.middleware ++ [middleware]}
  end
end
