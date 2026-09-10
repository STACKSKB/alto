# Changelog

## Unreleased

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
