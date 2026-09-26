defmodule Alto.Persistence.Retained do
  @moduledoc """
  Small shared primitives for revision-fenced records retained in an
  Alto.OperationLog.

  Domain modules own packet validation and state transitions. This module only
  bounds calls by an absolute monotonic deadline and provides atomic initialization,
  compare-and-swap, and deterministic lifecycle completion.
  """

  alias Alto.OperationLog

  @default_call_timeout 5_000

  @doc "Validate options for a retained-record lookup and return its deadline."
  def deadline([]), do: {:ok, :infinity}

  def deadline(deadline: deadline),
    do: with(:ok <- deadline_ok(deadline), do: {:ok, deadline})

  def deadline(_), do: {:error, :invalid_retained_options}

  def deadline_ok(:infinity), do: :ok

  def deadline_ok(deadline) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :run_timeout}
  end

  def deadline_ok(_), do: {:error, :invalid_deadline}

  def call_timeout(:infinity), do: @default_call_timeout

  def call_timeout(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  def call_timeout(_), do: 0

  @doc "Execute a native ledger request under the supplied absolute monotonic deadline."
  @spec request(GenServer.server(), OperationLog.request(), integer() | :infinity) :: term()
  def request(ledger, message, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         do: OperationLog.request(ledger, message, call_timeout(deadline))
  end

  @doc "Create an internal checkpoint atomically, or read the existing record."
  def ensure_checkpoint(ledger, key, tool, recovery, attempt, packet, deadline \\ :infinity) do
    with :ok <- request(ledger, {:retain, key, tool, recovery, attempt, packet}, deadline),
         do: request(ledger, {:recovery, key}, deadline)
  end
end
