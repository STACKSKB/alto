# Alto documentation

Start with the [project overview](../README.md), then choose a configuration and
interface for your workflow.

## Using Alto

| Guide | What it covers |
| --- | --- |
| [Configuration](configuration.md) | Defaults, providers, multiple `alto.exs` profiles, attachments, sessions, and named runs |
| [Terminal UI](../packages/alto_tui/README.md) | Running the TUI, keyboard controls, workspaces, and backend composition |
| [Examples](../examples/README.md) | Coding profile, repository maintenance, document intake, and an optional Oban host |
| [Conversation revisions](conversations.md) | Saved history, dispatch fences, resuming, and branching |
| [Interactive input](interactive-input.md) | Steering, follow-ups, and shared messaging channels |
| [Subagents](subagents.md) | Model selection, teams, inherited authority, child sessions, and isolated workspaces |
| [Context reduction](context-reduction.md) | Triggers, reducers, pinned messages, and reduction limits |
| [Tool batches](tool-batches.md) | Explicit concurrent calls and ordered outcomes |

## Building with Alto

| Contract | What it covers |
| --- | --- |
| [Extensions](extensions.md) | Prompts, providers, tools, typed content, approvals, middleware, executors, and host callbacks |
| [Loops](loop-contract.md) | Typed lifecycle events and a replaceable control policy |
| [Execution hosts](runners.md) | Runner lifecycle, manual execution, shared components, and retention |
| [Front-end protocol](../PROTOCOL.md) | Unix socket and WebSocket clients, events, approvals, sessions, and queues |
| [SSE adapter](sse-adapter.md) | Incremental provider stream parsing and bounds |
| [Delayed work](delayed-queue.md) | Persisted due times and queue claim/ack semantics |
| [Approval continuations](checkpoints.md) | Suspending prepared operations and restoring approved work |
| [Parent continuations](parent-continuations.md) | Recovering a parent around a retained child batch |
| [Child continuations](child-continuations.md) | Independent child approvals and durable joins |
| [Benchmarks](benchmarks.md) | Reproducible offline scheduling, storage, and TUI workloads |

The [changelog](../CHANGELOG.md) records releases. API guides describe the source
in this checkout; consult the matching Git tag when using an older release.
