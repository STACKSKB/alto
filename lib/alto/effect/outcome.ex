defmodule Alto.Effect.Outcome do
  @moduledoc """
  External effect outcomes, independent of approval and retry policy.

  * `:completed`: the effect or observation definitely completed.
  * `:rejected_before_dispatch`: validation, preparation, or approval prevented
    execution. Preparation must be free of side effects.
  * `:failed_known`: the participant explicitly reports failure without commit.
  * `:unknown`: dispatch occurred but its outcome is uncertain, including
    execution timeout, crash, malformed return, or cancellation after dispatch.
  * `:requires_operator`: consumer/operator policy parked the operation.

  Outcomes never grant permission to retry or compensate. Unknown effects
  require authoritative reconciliation or operator review. Tool mutation is
  declared by `approval/1` and the participant contract, independently of outcome.
  Runner tool events carry their outcome; the result retains the aggregate verdict
  independently of the bounded event history.
  """

  @type class ::
          :completed
          | :rejected_before_dispatch
          | :failed_known
          | :unknown
          | :requires_operator
end
