defmodule Alto.Command.Executor do
  @moduledoc "Prepare and execute a validated command using one backend."

  alias Alto.Command.Invocation

  @callback prepare(Invocation.t(), keyword()) ::
              {:ok, execution :: term(), approval_details :: map()} | {:error, term()}

  @callback execute(execution :: term()) :: {:ok, map()} | {:error, term()}

  @doc "Open a retained stdio process. The caller owns protocol framing and lifetime bounds."
  @callback open(execution :: term(), keyword()) ::
              {:ok, Alto.External.Process.t()} | {:error, term()}
  @optional_callbacks open: 2
end
