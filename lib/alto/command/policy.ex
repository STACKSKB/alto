defmodule Alto.Command.Policy do
  @moduledoc "Policy contract for validating and resolving a requested command."

  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @callback prepare(arguments :: map(), Context.t(), keyword()) ::
              {:ok, Invocation.t()} | {:error, term()}
end
