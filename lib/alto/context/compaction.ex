defmodule Alto.Context.Compaction do
  @moduledoc """
  Domain-specific context reduction for the execution host.

  Configure `compaction: [strategy: {MyReducer, options}]`. The runner selects
  complete transcript groups, bounds source bytes, supervises callbacks and
  any provider call, applies shared budgets, validates the replacement, and
  persists it in the session. Tool calls are disabled during reduction.

  A deterministic reducer can implement `reduce/3` and return replacement text
  without a provider. Provider-backed reducers implement `request/3` and
  `decode/3`. If both forms are present, `reduce/3` takes precedence.
  """

  @callback reduce(String.t(), pos_integer(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback request(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback decode(map(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @optional_callbacks reduce: 3, request: 3, decode: 3
end
