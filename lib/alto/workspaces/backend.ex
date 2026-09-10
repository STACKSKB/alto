defmodule Alto.Workspaces.Backend do
  @moduledoc """
  Behaviour implemented by workspace providers.

  The first three callbacks provide the core workspace lifecycle. Providers
  that can integrate a frozen patch may also implement the three optional
  integration callbacks. Verification and dispatch receive the manager-owned
  source identity so providers can bind their target before mutation; managers
  never assume that integration is Git.
  """

  @callback snapshot(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback checkout(map(), Path.t(), keyword()) :: :ok | {:error, term()}
  @callback diff(map(), Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}

  @callback prepare_apply(Path.t(), Path.t(), binary(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback verify_apply(Path.t(), map(), Path.t(), keyword()) :: :ok | {:error, term()}
  @callback apply(Path.t(), map(), Path.t(), keyword()) ::
              {:ok, map()} | {:unknown, term()} | {:error, term()}

  @optional_callbacks prepare_apply: 4, verify_apply: 4, apply: 4
end
