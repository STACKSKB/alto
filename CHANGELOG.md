# Changelog

## Unreleased

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
