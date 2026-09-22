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
  def deadline(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:deadline]] do
      deadline = Keyword.get(opts, :deadline, :infinity)
      with :ok <- deadline_ok(deadline), do: {:ok, deadline}
    else
      {:error, :invalid_retained_options}
    end
  end

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

  def resume(ledger, key, expected_revision, decision, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline) do
      OperationLog.resume_checkpoint(
        ledger,
        key,
        expected_revision,
        decision,
        call_timeout(deadline)
      )
    end
  end

  @doc "Finish an internal lifecycle transition using its deterministic attempt."
  def finish(ledger, key, attempt, evidence, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         :ok <- OperationLog.record_attempt(ledger, key, attempt, call_timeout(deadline)),
         :ok <- deadline_ok(deadline) do
      OperationLog.record_outcome(
        ledger,
        key,
        attempt,
        :completed,
        evidence,
        call_timeout(deadline)
      )
    end
  end
end
