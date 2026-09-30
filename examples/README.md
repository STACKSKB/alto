# Alto examples

Start with [`alto.agentic.exs`](../alto.agentic.exs) for a terminal coding agent.
It works with the CLI and optional TUI, and exposes tools, providers, approvals,
executors, and limits as an ordinary Elixir keyword list. Use the
[configuration guide](../docs/configuration.md) to derive separate profiles for
your models and sessions.

The application examples show how to embed Alto in a host that owns admission,
storage, and external integration. Alto supplies the configured execution loop,
approvals, cancellation, and resource bounds.

- [Repository maintenance](repository_maintenance/README.md) receives signed
  reports, diagnoses a detached checkout, runs configured verification, and
  records a reviewed patch manifest before applying changes.
- [Document intake](document_intake/README.md) classifies and extracts real
  Markdown or text, keeps source identity and corrections, and publishes
  versioned JSON/CSV artifacts atomically.
- [Optional Oban host](oban_backend/README.md) shows durable admission and a
  worker that sends unknown external outcomes to explicit reconciliation.
- [Extension boundaries](../docs/extensions.md) shows host-side input
  transforms, provider-aware context estimates, hooks, trusted commands, and
  optional renderers and provider adapters.

The repository maintenance and document intake runners execute from
`packages/alto_contrib`; Oban declares contrib as a host dependency. Each example
has its own run instructions and integration checks.
