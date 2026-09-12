defmodule Alto.Persistence.Retained do
  @moduledoc """
  Small shared primitives for revision-fenced records retained in an
  Alto.OperationLog.

  Domain modules own packet validation and state transitions. This module only
  bounds calls by an absolute monotonic deadline and provides the common
  intent-convergence and compare-and-swap operations.
  """

  alias Alto.OperationLog

  @default_call_timeout 5_000

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

  @doc "List retained operation keys under the supplied absolute deadline."
  def keys(ledger, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         do: OperationLog.keys(ledger, call_timeout(deadline))
  end

  @doc "Converge concurrent creation attempts on one immutable intent."
  def ensure_intent(ledger, key, tool, inbox, recovery, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline) do
      case read(ledger, key, deadline) do
        {:error, :not_found} ->
          case OperationLog.record_intent(
                 ledger,
                 key,
                 tool,
                 inbox,
                 recovery,
                 call_timeout(deadline)
               ) do
            :ok -> read(ledger, key, deadline)
            {:error, :intent_conflict} -> read(ledger, key, deadline)
            {:error, _} = error -> error
          end

        other ->
          other
      end
    end
  end

  @doc "Apply a replacement at an exact retained revision."
  def cas(ledger, key, expected_revision, replacement, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         {:ok, entry} <-
           OperationLog.update_checkpoint(
             ledger,
             key,
             expected_revision,
             replacement,
             call_timeout(deadline)
           ) do
      {:ok, entry}
    end
  end

  def resume(ledger, key, expected_revision, decision, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         result <-
           OperationLog.resume_checkpoint(
             ledger,
             key,
             expected_revision,
             decision,
             call_timeout(deadline)
           ) do
      result
    end
  end

  def record_attempt(ledger, key, attempt, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         result <- OperationLog.record_attempt(ledger, key, attempt, call_timeout(deadline)) do
      result
    end
  end

  def record_checkpoint(ledger, key, attempt, packet, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         result <-
           OperationLog.record_checkpoint(
             ledger,
             key,
             attempt,
             packet,
             call_timeout(deadline)
           ) do
      result
    end
  end

  def record_outcome(ledger, key, attempt, class, evidence, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         result <-
           OperationLog.record_outcome(
             ledger,
             key,
             attempt,
             class,
             evidence,
             call_timeout(deadline)
           ) do
      result
    end
  end
end
