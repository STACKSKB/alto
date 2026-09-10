# Examples

These examples show how to compose Alto around real application boundaries.
They are intentionally small: the host owns authentication, persistence,
retry policy, and external side effects, while Alto owns the configured run,
approval, and resource limits.

- [Repository maintenance](repository_maintenance/README.md) receives signed
  reports, diagnoses a detached checkout, runs configured verification, and
  records a reviewed patch manifest before applying changes.
- [Document intake](document_intake/README.md) classifies and extracts real
  Markdown or text, keeps source identity and corrections, and publishes
  versioned JSON/CSV artifacts atomically.
- [Optional Oban host](oban_backend/README.md) shows durable admission and a
  worker that sends unknown external outcomes to explicit reconciliation.
- [`alto.agentic.exs`](../alto.agentic.exs) is a full local coding profile for
  the optional terminal UI and one-shot CLI. It keeps command execution,
  approvals, provider settings, and bounds visible in compiled configuration.

The repository maintenance and document intake flows operate on local files and
include their own host-side integration checks. Provider fixtures exercise
Alto's contracts; they do not claim a live paid-provider result.
