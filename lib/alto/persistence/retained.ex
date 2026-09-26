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

  @doc "Read a retained operation under the supplied deadline."
  def read(ledger, key, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         do: OperationLog.recovery(ledger, key, call_timeout(deadline))
  end

  @doc "Read one consistent set of operation views under the supplied deadline."
  def entries(ledger, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         do: OperationLog.entries(ledger, :all, call_timeout(deadline))
  end

  @doc "Create an internal checkpoint atomically, or read the existing record."
  def ensure_checkpoint(ledger, key, tool, recovery, attempt, packet, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         :ok <-
           OperationLog.retain(
             ledger,
             key,
             tool,
             recovery,
             attempt,
             packet,
             call_timeout(deadline)
           ),
         do: read(ledger, key, deadline)
  end

  @doc "Apply a replacement at an exact retained revision."
  def cas(ledger, key, expected_revision, replacement, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline) do
      OperationLog.update_checkpoint(
        ledger,
        key,
        expected_revision,
        replacement,
        call_timeout(deadline)
      )
    end
  end

  @doc "Retire a checkpoint atomically after validating its viewed revision."
  def retire(ledger, key, revision, decision, attempt, evidence, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline) do
      OperationLog.retire_checkpoint(
        ledger,
        key,
        revision,
        decision,
        attempt,
        evidence,
        call_timeout(deadline)
      )
    end
  end
end
