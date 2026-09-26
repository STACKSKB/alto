# Shared interactive input

An interactive host can attach a bounded channel to any shared execution host:

```elixir
{:ok, input} = Alto.Input.start_link(max_messages: 32, max_bytes: 64_000)
{:ok, run} = Alto.start("Inspect this project", input: input, provider: provider)
Alto.Messaging.send(input, text: "Focus on the parser", delivery: :steer)
Alto.Messaging.send(input, text: "Then explain the change", delivery: :follow_up)
Alto.await(run)
```

Steering arrives before the next model request once outstanding tool calls have
settled. Follow-ups arrive when the loop would otherwise finish. Neither mode
cancels or conceals already dispatched work. A live provider call continues to
its boundary; use ordinary run cancellation when immediate termination is
needed.

Delivery appends a user message and emits `:input_received` through the existing
loop middleware. The default loop starts another model step. Custom loops decide
how to react to that event. Follow-ups share the original run's model/effect
budgets and deadline; delivery never refreshes them.

Each channel has one active consumer, preventing concurrent runs from inserting
the same message. Messages are acknowledged only after transcript insertion;
failed insertion leaves them queued. A channel outlives a consumer crash, if its
own host remains alive, and can be attached to a later run. `Alto.Input.list/1`
reports pending entries. The channel itself is in memory, so hosts needing
durable ingress should retain submissions in their application store.

An accepted enqueue is not a promise of delivery: a run may finish or exhaust
its budget before consuming it. Hosts should inspect pending entries on
completion and decide whether to start another run. Checkpoints do not serialize
the channel; the host explicitly supplies it again on resume.

In the optional TUI, Enter queues a native Alto follow-up while a run is active,
and Ctrl+Enter submits native steering input for the next model boundary. Input
accepted near completion, cancellation, or failure remains pending until the
next eligible run; the TUI keeps the composer draft and lets Enter retry
delivery. Existing custom and Codex backends keep their established local
follow-up queues and controls.

## Shared user and agent messaging

`Alto.Messaging.send/2` is the host-facing form of the same ingress used by
agent tools:

```elixir
{:ok, input} = Alto.Input.start_link()
{:ok, run} = Alto.start("Inspect the parser", input: input, provider: provider)
{:ok, receipt} = Alto.Messaging.send(input,
  text: "Focus on JSON", delivery: :steer, idempotency_key: "submission-1")
Alto.Input.receipt(input, receipt.message_id)
# {:ok, %{message_id: "msg-...", status: :queued | :consumed}}
```

A receipt means admission to the in-memory channel. `:consumed` means inserted
into the transcript, not understood, obeyed, or answered. Consumption emits
`:input_received` with `message_id`, `sender`, `text`, and `mode`. A retry using
the same sender, recipient, and idempotency key returns its existing receipt;
changing the message under that key returns `:idempotency_conflict`. Receipt
history is capped at 4,096 per channel and rejects further
submissions when full. Text is capped at 64 KB; routed metadata also counts
against the channel's byte limit. Acceptance never promises crash recovery
or exactly-once model execution.

Every shared execution run registers an opaque agent address. A router scopes
addresses and runtime-issued sender capabilities to one execution tree. To
inspect or send to children from a host, supply a router explicitly:

```elixir
{:ok, router} = Alto.Messaging.start_link()
{:ok, run} = Alto.start("Review the parser", messaging: router, provider: provider,
  tools: Alto.Tools.agents(), loop: loop)
{:ok, agents} = Alto.Messaging.list(router)
Alto.Messaging.send(router, agent_id, text: "Please check empty input")
```

Registration occurs as the run starts; early listings may be empty. Hosts own
explicit routers and should stop them when no longer needed. Automatic routers
end with the root execution. Routing retains at most 256 agent instances,
including closed addresses, so reusing a display label cannot redirect an old
message to a new child. Sends to unknown, closed, or unsupported recipients
return explicit errors. Successfully admitted input remains queued if the run
ends before consuming it; hosts with reusable input channels can inspect
`Alto.Input.list/1`. `Alto.Input.take(input, :user)` starts only user submissions
as new turns, preserving peer-message provenance during host retries. Taking an
entry transfers it to the host and marks its receipt `:taken`; this does not
claim that a subsequent run has inserted it into a transcript.

Agent messages carry runtime-derived identity and enter provider history as
explicitly attributed peer context. They do not replace the default loop's
current task. User messages retain the existing task-steering behavior. Custom
loops receive the structured `:input_received` event and choose their response.
Neither delivery mode grants tools, changes approvals, refreshes budgets, nor
interrupts already dispatched work. The Codex whole-agent adapter currently
advertises `messaging: false` and rejects live message delivery.

The front-end protocol exposes `send_message` and `list_agents`; the TUI uses
the same host ingress for Enter and Ctrl+Enter. See [PROTOCOL.md](../PROTOCOL.md).
