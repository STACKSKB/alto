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
reports pending entries. Memory is the default transport. File-backed and custom transports use the same
mailbox interface; see below.

An accepted enqueue is not a promise of delivery: a run may finish or exhaust
its budget before consuming it. Hosts should inspect pending entries on
completion and decide whether to start another run. Checkpoints retain queue contents, receipt history, deduplication keys and stable
agent addresses. Connections, reader leases and credentials are recreated from
host configuration on resume.

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
message to a new child. Sends to unknown or closed recipients
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
interrupts already dispatched work. The Codex whole-agent adapter accepts live steering and follow-ups, and can call
the same authorized messaging tools as its parent.

The front-end protocol exposes `send_message` and `list_agents`; the TUI uses
the same host ingress for Enter and Ctrl+Enter. See [PROTOCOL.md](../PROTOCOL.md).

## Composable transports and checkpoints

Use `Alto.Input.open/1` for an explicit host channel, or configure the transport
for every mailbox created by a runner or front-end configuration:

```elixir
Alto.start("Inspect the parser",
  provider: provider,
  messaging_transport: {Alto.Messaging.Transport.File, directory: "/private/alto-mailboxes"},
  checkpoint_version: "application-v1"
)

{:ok, input} = Alto.Input.open(
  transport: {Alto.Messaging.Transport.File, directory: "/private/alto-mailboxes"},
  id: "host-inbox"
)
```

Omitting the transport uses in-memory `Alto.Input`. A custom module implements
`Alto.Messaging.Transport`: `open(options)`, `request(handle, operation, timeout)`
and `close(handle)`. The runtime supplies `:id`, a stable mailbox address, in
`open/1` options. An SSH adapter can forward requests to a remote mailbox service;
a polling adapter can transact against another store. Core execution does not
assume a socket, filesystem, polling interval, or SSH command.

The request protocol is defined by `Alto.Input.request/3` and its public wrappers.
Implementations must provide atomic admission, deduplication, exclusive reader
claim/release, opaque delegated readers, acknowledgement, snapshot and restore.
`:checkpoint` returns the same portable state as `:snapshot` and seals admission;
new sends return `:input_checkpointed` until restore, while duplicate sends still
return their original receipt. This fences the snapshot against accepting and
then losing late messages. Snapshot inspection alone does not seal admission.
Transports must retain newer writes/receipts when restoring the same durable
mailbox, and reject conflicting state rather than overwriting it. Cross-store
migration requires a quiesced source and the host's existing one-use checkpoint
fence. Checkpoint format 3 is required; earlier continuation formats are rejected.

The supplied file transport uses private files, atomic replacement and OS advisory
locks. Writers can open independent handles to the same address. The reader holds
an OS lifetime lock; a crashed reader releases it without waiting for a lease to
expire. Use a filesystem that supports flock and atomic rename; this is not a
claim that arbitrary network filesystems have those semantics. Files and receipts
persist after a run, and retention/removal belongs to the host.

## Codex live delivery

The delegated adapter calls App Server `turn/steer` with the active turn ID.
`follow_up` starts another turn in the same thread after the current turn finishes.
Peer messages retain their agent identity and are explicitly labeled peer context.
`list_agents` and `send_message` are experimental App Server dynamic tools, exposed
only when those exact built-in capabilities are model-visible in the parent.
Each delivery/tool call consumes the shared Alto effect budget. Codex's internal
model requests remain externally accounted.

Receipts report `:delivered` after App Server accepts input. Before network dispatch,
the adapter records `:unknown`; a timeout, disconnect, stale turn rejection, or crash
leaves that receipt explicit and prevents automatic replay. Hosts must reconcile
uncertain delivery before choosing to submit a new message. Delivery does not mean
the agent followed the instruction. Duplicate dynamic call IDs reuse their response;
conflicting calls and mismatched thread/turn IDs are rejected. Permission requests
remain subject to the adapter's existing read-only boundary.

An external Codex turn is one Alto effect: checkpointing waits for that effect to
settle. It does not serialize a running App Server process or interrupt and replay
an external turn. The official protocol contracts are documented in
[Codex App Server](https://learn.chatgpt.com/docs/app-server).
