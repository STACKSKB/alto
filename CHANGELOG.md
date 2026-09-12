# Changelog

## Unreleased

- Add durable parent-batch continuations and independently approved child
  continuations, with single-use grants and explicit retirement/cleanup hooks.
- Validate child checkpoints before workspace activation; rejected recovery
  preserves the exact worked workspace for a later valid attempt.
- Add read-only retained-resource lookup and continuation discovery, plus
  revision-fenced child approval inspection for application hosts.
- Reject unavailable durable identities during checkpoint capture instead of
  retaining a process-dependent fingerprint; converge concurrent journal retirement.

- Add optional child dispatch journals with exact retained results, revision-fenced
  join acknowledgement and explicit retirement. Children persist their own results
  before returning; uncertain dispatches are never automatically repeated.

- Add optional durable shared effect/model-count accounts on the operation
  ledger. Restored budgets reconnect to current counters; tightened limits,
  generation fencing and account closure prevent replenishing old allowances.
- Add revision-fenced retained checkpoint updates without execution grants.

- Add optional separate child sessions with independent transcript snapshots,
  parent/identity links and child session IDs in delegation results. Shared
  session behavior remains the default.

- Add opt-in bounded queue compaction with exact live-claim and dedup-window
  retention. Version 3 snapshots reject incomplete retained state and preserve
  record ID progression across restarts.

- Add prepared, revision-fenced application of captured workspace patches with
  stale-file checks, retained application evidence and conservative interruption
  recovery. Preparation and application preserve the source Git index.

- Replace ambiguous approval click hints with fixed, labeled Approve and Deny buttons.
- Show TUI run phases and keep pending approval controls visible while composing.
- Queue one follow-up per task and allow Esc cancellation without losing drafts.
- Clear expired approval prompts and release tasks after abnormal run exits.
- Show insertion cursors in provider and model forms while masking API keys.
- Expose resident run summaries and bounded saved conversations to reconnecting clients.
- Save a JSON projection alongside exact event payloads so fresh-VM replay
  does not depend on atoms loaded by an earlier execution.
- Add persisted due times and fenced delayed release to the existing queue.
  Scheduled records use log version 2 so old readers cannot execute them early.
  See [delayed queue semantics](docs/delayed-queue.md).
- Add bounded session event replay over the frontend protocol, with stable
  ordinals, readable payloads and detection of cursors beyond stored history.
- Add optional owner-bound asynchronous runs. Resident registry termination
  cooperatively cancels its executions and in-flight provider/tool callbacks.

## 0.0.1

Initial public release.

- Composable model-driven and deterministic execution with bounded subagents.
- Approval-controlled tools, shared execution budgets, cancellation, and explicit uncertain outcomes.
- Durable sessions, queues, operation reconciliation, and configurable context reduction.
- Provider, tool, command, search, ingress, and transport extension contracts.
- CLI and optional terminal UI example, plus repository-maintenance and document-intake examples.
- MIT license.

- Added replaceable runner lifecycle contracts, neutral results, and a Stepped
  host sharing extracted execution components with Serial.
- Decoupled workspace integration from Git and journal serialization from runners.
- Fixed checkpoint bindings across store-process restarts and bounded durable
  accounting/journal calls by execution deadlines.
- Bound application command callbacks and report timeout outcomes as uncertain.
