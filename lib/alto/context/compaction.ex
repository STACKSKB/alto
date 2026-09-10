defmodule Alto.Context.Compaction do
  @moduledoc """
  Domain-specific context reduction for the serial runner.

  Configure `compaction: [strategy: {MyReducer, options}]`. The runner selects
  complete transcript groups, bounds source bytes, supervises both callbacks
  and the provider, applies shared budgets, validates the replacement, and
  persists it in the session. Callbacks only build a request and decode its
  answer. Tool calls are disabled during reduction.
  """

  @callback request(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback decode(map(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
