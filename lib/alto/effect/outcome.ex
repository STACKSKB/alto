defmodule Alto.Effect.Outcome do
  @moduledoc """
  The smallest compatible vocabulary for external effect outcomes.

  Five classes, and only five:

    * `:completed` — the effect definitely applied (or, for a read-only
      tool, the observation definitely completed).
    * `:rejected_before_dispatch` — the effect definitely did *not* run:
      validation, unknown tool, exposure, approval denial/failure, and
      preparation failures all land here. Preparation is contractually
      side-effect-free, so anything that fails before dispatch proves
      non-commit.
    * `:failed_known` — the participant ran and says it did not commit.
      This trusts the participant's explicit `{:error, reason}` signal; a
      tool that commits and then reports an error is lying, which is a
      tool-author bug outside what any harness vocabulary can fix (RISKS.md).
    * `:unknown` — the effect may or may not have committed: supervision
      timeouts and crashes during execution, malformed returns, dropped
      oversize results, and cancellation after dispatch. Recovery must
      consult the authoritative participant or park the work — never assume
      either way, and never retry blindly.
    * `:requires_operator` — parked for a human. Assigned by consumers and
      operators, never by the serial runner.

  The classes are deliberately independent axes from everything else:

    * **mutation** — whether the tool mutates is declared by `approval/0`
      and the tool's own contract, not by its outcome;
    * **approval** — the approval decision authorizes dispatch; it says
      nothing about the outcome;
    * **idempotency** — whether re-dispatch is safe is a connector property
      (idempotency keys), not something an outcome class confers;
    * **retryability** — no outcome class implies permission to retry. The
      serial runner never retries tools (boundary); retry is an
      explicit, visible consumer policy;
    * **reconciliation** — how to resolve `:unknown` (ask the participant,
      check external state, park) is consumer/operator policy;
    * **compensation** — undoing a committed effect is an ordinary
      domain-specific operation, never an automatic harness behavior.

  Existing `Alto.Tool` return values remain unchanged; the runner tags tool
  events with an additive `outcome:` key derived here.
  """

  @type class ::
          :completed
          | :rejected_before_dispatch
          | :failed_known
          | :unknown
          | :requires_operator

  @doc "All outcome classes in severity order (informational only)."
  @spec classes() :: [class()]
  def classes,
    do: [:completed, :rejected_before_dispatch, :failed_known, :unknown, :requires_operator]

  @doc "True for the terminal decided classes (everything but `:unknown`)."
  @spec decided?(class()) :: boolean()
  def decided?(:unknown), do: false
  def decided?(_class), do: true
end
