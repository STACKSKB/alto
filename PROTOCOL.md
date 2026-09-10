# Alto front-end protocol — v1

Status: **implemented (v1).** This document fixes the wire contract for
processes that talk to a running Alto core: graphical front ends, other
agents, and scripts. `input` and `reload` remain reserved (v1 servers reply
`unsupported`); the other messages below are part of the v1 contract.

The governing idea: **the envelope is the protocol; transports are framing.**
The core Alto process listens for typed inputs — from a human, an agent, or
another program — and streams typed facts back out. Which toolkit renders the
human-facing view is a client decision this
protocol deliberately does not make.

## Design principles

1. **The UI is a view, never the authority.** Approval, execution, sandboxing,
   and cancellation stay host-owned. A socket client can
   *request*; only the host decides. A crashed or malicious client can never
   widen what the host is willing to do.
2. **Serialize existing contracts; invent as little as possible.** Events on
   the wire are the existing `Alto.Event` values; approval requests are the
   existing display-safe `Alto.Approval.Request`. No second event model.
3. **The durable log is the source of truth; the wire may be lossy.** Event
   payloads contain Elixir terms (atoms, tuples) that JSON cannot carry
   exactly. The encoding below is deliberately lossy-but-stable for display.
   Exactness is recovered from the durable log, never from the wire.
4. **Bounds are part of correctness**. Every message
   size is bounded; the protocol never emits an unbounded payload, and
   oversized material is surfaced as an explicit protocol event, not silently
   truncated mid-envelope.
5. **No code over the wire.** Clients reference trusted, server-side compiled
   `Alto.Config` specifications by name. Loop, provider, tool, and policy
   modules are never transmitted or resolved from client input.

## Process model

The core Alto process is the listener. There is no separate daemon with its
own semantics — the same core that runs `alto "task"` one-shot can run as a
resident process whose listener component is enabled by configuration:

- **One-shot** (shipped today): the process starts, performs the run, prints,
  and exits. No listener.
- **Resident** (this protocol): the process stays up, owns zero or more runs,
  and accepts client connections. Clients are unprivileged: a status line, a
  transcript pane, a diff-preview pane, and an approval prompt are all
  independent connections; none is privileged over another.

The listener is a component selected and parameterized by the user's compiled
Elixir configuration, like executors and approval policies today. It owns no
policy: it validates framing and forwards; the host still decides
authorization and execution at its existing boundaries.

## Transports

- **v1 default transport: Unix domain socket + NDJSON.** Zero new
  dependencies (OTP `:gen_tcp` with a `{:local, path}` bind). One JSON
  envelope per line, UTF-8, terminated by `\n`. Served by
  `Alto.Listeners.UnixSocket`.
- **WebSocket transport (shipped).** One envelope per text frame, same bytes,
  served by `Alto.Listeners.WebServer`: a localhost HTTP listener whose
  `GET /` serves the built-in single-page GUI (`Alto.FrontEnd.Gui`) and whose
  `GET /ws` upgrades to the front-end protocol. Upgrades are accepted only
  from same-origin pages (or non-browser clients with no `Origin` header).
  Bandit, Plug, and WebSock own HTTP and RFC 6455 mechanics; Alto's
  transport-independent `Alto.Listeners.Connection` owns envelopes and
  commands. Nothing above the framing layer may assume either transport.

Framing rules for NDJSON (both directions):

- The sender MUST NOT emit empty lines; a receiver MUST ignore them.
- A line longer than the configured `max_line_bytes` (default 1 MiB) is never
  truncated: the receiver closes the connection. Truncating a stream that
  carries approval decisions is unsafe; closing is the fail-closed behavior.
- Malformed JSON on a line produces an `error` reply, not a disconnect, unless
  the line exceeded the size limit.

## Envelope

Every message, both directions, is one JSON object:

```json
{"v": 1, "type": "...", "id": "c-12", ...payload}
```

| field | required | meaning |
|---|---|---|
| `v` | yes | protocol version, integer `1` |
| `type` | yes | discriminator string, see message catalogs |
| `id` | yes | sender-chosen correlation token (any non-empty string); replies echo the `id` of the request they answer |

Field naming is snake_case, matching existing map shapes. Receivers MUST
ignore unknown fields (forward compatibility) and MUST reply with `error`
(code `unknown_type`) to unknown `type` values without closing the connection.

### Term encoding

Event `data` and approval `details` contain Elixir terms. The wire encoding
is a documented, stable, lossy convention:

| Elixir term | wire form |
|---|---|
| integers, floats, strings, booleans | as-is |
| `nil` | `null` |
| atoms | strings (`:approved` → `"approved"`) |
| maps | objects; atom keys become strings |
| lists | arrays |
| tuples | `{"$tuple": [elements...]}` |
| anything else | `{"$inspect": "<bounded inspect/1 string>"}` |

Encoders MUST apply the existing upstream bounds before encoding: tool result
content is already truncated by `max_tool_result_bytes`, approval details
already fail closed above `max_approval_details_bytes` (64,000 bytes) before
approval is requested. An envelope whose encoding would exceed
`max_line_bytes` is not emitted truncated; the encoder emits `overflow`
instead. Every event type's encoding is pinned by characterization tests as
it is implemented.

## Messages: server → client

**`hello`** — sent immediately after a connection is accepted.

```json
{"v": 1, "type": "hello", "id": "s-1",
 "runs": ["run-41"], "max_line_bytes": 1048576}
```

`runs` lists currently live run ids (run ids are the host's `session_id`
values, format `run-<integer>`).

**`event`** — one typed fact, matching `Alto.Event`.

```json
{"v": 1, "type": "event", "id": "s-2", "run_id": "run-41",
 "seq": 7, "domain": "durable", "at_ms": 1788268819423,
 "event": {"type": "tool_completed",
           "data": {"call_id": "call-1", "operation_id": "run-41:op-1",
                    "run_id": "run-41", "name": "echo",
                    "output": "{\"echo\":\"hi\"}"}}}
```

Tool events carry both `call_id` (correlation, repeatable) and
`operation_id`/`run_id` (globally unique runtime operation). `tool_completed`
additionally carries `value` (bounded native term) alongside the legacy
`output` string; oversize natives are rejected as `tool_failed`
(`{:tool_result_too_large, ...}`) before retention, fanout, or persistence,
never silently truncated.

`seq` is a per-run, gapless, monotonically increasing integer on `durable`
events and `null` on `live` events. Durable event types shipped today:
`model_completed`, `tool_completed`, `tool_failed`, `step_settled`,
`run_cancelled`. Live types: `model_started`, `model_delta`, `tool_started`,
`approval_requested`, `approval_resolved`.

**`attached`** — reply to `attach`.

```json
{"v": 1, "type": "attached", "id": "c-3", "run_id": "run-41",
 "gap": false, "head_seq": 9,
 "events": ["...durable event envelopes, same shape as event messages..."]}
```

`events` replays durable events from the requested `from_seq` (inclusive) to
`head_seq`. `gap: true` means the requested range predates the listener's
bounded buffer; the replay starts at the earliest retained `seq` instead, and
the client knows it is missing history.

**`approval_request`** / **`approval_resolved`** — the display-safe approval
surface, from `Alto.Approval.Request`.

```json
{"v": 1, "type": "approval_request", "id": "s-5", "run_id": "run-41",
 "request": {"id": "run-41:op-1", "run_id": "run-41",
             "call_id": "call-1", "operation_id": "run-41:op-1",
             "tool": "echo",
             "arguments": {"value": "hello"},
             "execution_mode": "exclusive",
             "details": {"cmd": "/usr/bin/ls", "argv": ["ls"], "cwd": "/tmp"}}}
```

Identities: `run_id` is the host run; `call_id` is the
provider/native tool-call correlation token (repeatable, nullable, never a
handle); `operation_id` is the globally unique runtime operation
(`"<run_id>:op-<seq>"`); `id` is the approval handle, 1:1 with
`operation_id`. A client answers with `approval_response` carrying the
handle in `request_id`, never the bare `call_id`.

Wire compatibility (v1 breaking clarification): servers before this change
emitted `"id": "<call_id>"` with no `run_id`/`call_id`/`operation_id`
fields. Clients that assumed `id == call_id` must migrate to the handle
plus `call_id` correlation. Receivers must still ignore unknown fields, so
old clients see a globally unique `id` and can answer it unchanged; new
clients must not assume `id` equals any provider id.

`details` is the same bounded display map the interactive CLI shows. A client
answers with `approval_response`. If no response arrives inside the host's
`approval_timeout`, the host fails closed — a closed or hung client cannot
stall a run, and cannot widen it either. Pending approvals are replayed on
`attach` (including wildcard attaches), so a reconnecting client can still
answer; the first decision wins and late duplicates answer `not_found`.

**`result`** — terminal run result. The transcript and full event list are not
repeated; durable events were already streamed.

```json
{"v": 1, "type": "result", "id": "s-9", "run_id": "run-41",
 "outcome": "ok", "output": "finished", "model_requests": 3}
```

`outcome` is `"ok"`, `"error"` (then `reason` is present), or `"cancelled"`
(then `reason` is present).

**`overflow`** — the server dropped material a client subscribed to.

```json
{"v": 1, "type": "overflow", "id": "s-11", "run_id": "run-41",
 "domain": "live", "last_seq": 9}
```

`domain` is `"live"` (dropped in-flight signals; no action required) or
`"durable"` (gap in the retained log; re-`attach` to resync).

**`error`** — reply to a failed or unsupported command.

```json
{"v": 1, "type": "error", "id": "c-4", "code": "unknown_type", "detail": "mumble"}
```

Codes: `unknown_type`, `invalid`, `unknown_run`, `not_found`, `unsupported`,
`internal`.

## Messages: client → server

**`auth`** — optional first client message, reserved for token auth. When the
listener is configured without a token (the v1 single-user default), it MUST
NOT be sent; when a token is configured, it MUST be the first message, and any
earlier command yields `error` (`invalid`).

**`attach`** — subscribe. Each client attaches to what it needs, i3-style.

```json
{"v": 1, "type": "attach", "id": "c-3", "run_id": "run-41",
 "from_seq": 1, "domains": ["durable", "live"]}
```

`run_id` may be omitted to subscribe to all present and future runs. A client
MAY open several connections with different subscriptions; the server treats
each independently.

**`start_run`** — start a run from a trusted server-side configuration.

```json
{"v": 1, "type": "start_run", "id": "c-5", "config": "my-alto-config",
 "task": "Explain this repository"}
```

`config` names a specification resolvable through the server's `Alto.Config`
discovery (explicit `--config` path, `ALTO_CONFIG`, or the per-user XDG path)
— the same trust boundary the CLI uses. It is never an inline module, loop
value, or provider spec. An `overrides` object is reserved: v1 servers MUST
reject any `overrides` field with `error` (`unsupported`) until an override
whitelist is specified. The reply is `ok` with the new `run_id`, or `error`
carrying the host's construction-failure reason (the same reasons the host
validates before starting, e.g. `provider_required`).

`start_run` accepts an optional `resume` session id to continue a persisted
session instead of starting fresh:

```json
{"v": 1, "type": "start_run", "id": "c-5", "config": "my-alto-config",
 "task": "Follow up", "resume": "sess-abc123"}
```

The reply is `ok` with the new `run_id` plus the continued `session_id`
(fresh runs on a sessions-enabled server also report their new
`session_id`; unpersisted runs omit it). Resume reuses the stored
transcript verbatim with the task as a fresh user message; provider,
tools, approval, and bounds come from the named configuration, so
credentials are re-resolved and never read from disk. An unknown session
answers `error` (`not_found`); a session without a completed-run snapshot
— a crashed run — answers `error` (`not_found`, detail
`no_resumable_transcript`) instead of running anything, reporting the
actual recoverable state. A malformed id answers `error` (`invalid`).
Old servers ignore the unknown `resume` field and start fresh (receivers
ignore unknown fields); clients that need resume must check the session
outlives the attempt via `sessions`.

**`sessions`** — list resumable sessions.

```json
{"v": 1, "type": "sessions", "id": "c-9"}
```

The reply is `ok` with `{"sessions": [...]}` summaries (`id`, `task`,
`runs`, `completed_runs`, `last_outcome`, newest first, capped) read from
the server's session directory — independent of the live-run replay
window, so evicted and restarted-away runs stay discoverable. An
unreadable store answers `error` (`internal`).

**`session_events`** — read a bounded page of durable events from a session,
including after the resident registry has restarted.

```json
{"v": 1, "type": "session_events", "id": "c-10",
 "session_id": "sess-1", "limit": 100, "cursor": 0, "run_id": "run-41"}
```

`cursor` is a stable durable event ordinal, independent of the live registry
`seq` values used by `attach`. The `ok` reply contains `events`, each with an
`ordinal`, plus `next_cursor`, `last_cursor`, `high_watermark`, `complete`,
and `gap`. `complete` means the page reached the current end of the session
log; it does not mean the run completed. Clients can retain `last_cursor` and
poll again later when the high watermark advances. `gap` is true when the
requested cursor is beyond the stored high watermark (for example, after a
state rollback). Corrupt logs and logs over 16 MB or 20,000 records fail
closed. Event `data` uses the same readable, lossy JSON term encoding as live
notifications; the session log retains the exact source terms.

Replay describes successfully persisted records. Session logging is
best-effort, and this cursor cannot prove that every execution event was
written. Persistence degradation remains part of the run result; `gap: false`
is not a claim that an execution had no persistence failures.

**`cancel`** — cooperative cancellation via the existing handle API.

```json
{"v": 1, "type": "cancel", "id": "c-6", "run_id": "run-41", "reason": "user"}
```

The reply is `ok`; the observable effect arrives as the durable
`run_cancelled` event and a `result` with `outcome: "cancelled"`.

**`approval_response`** — answer a pending approval request.

```json
{"v": 1, "type": "approval_response", "id": "c-7", "request_id": "run-41:op-1",
 "decision": "approve"}
```

`request_id` is the approval handle (`request.id`/`operation_id`), not the
`call_id`. `decision` is `"approve"` or `{"deny": "<reason>"}`. A `request_id`
that is already resolved, cancelled, or never pending yields `error`
(`not_found`); the host's approval timeout bounds how long a request stays
pending. Duplicate requests for the same handle answer `already_pending`
at registration time (registry `request_approval`).

**`input`** — RESERVED, not implemented in v1. Typed external event delivery
into a run (the model-independent boundary's "external events correlated with
runtime-owned jobs": rule loops, queue consumers, timers, webhooks). v1
servers reply `error` (`unsupported`). Reserving the type now keeps the later
addition from being a protocol break.

**`queue_claim`** — claim pending records from the server's durable queue
(`Alto.Queue`). New message types are additive.

```json
{"v": 1, "type": "queue_claim", "id": "c-9", "count": 5, "by": "station-1"}
```

`count` (optional, default 1, minimum 1) bounds the batch; `by` is an
optional client tag recorded with each claim. Replies are additionally
bounded by the connection's own `max_line_bytes`: at most `count` records
whose encoded form fits are leased, oldest first. A lone oversized
head answers `error` (`internal`, detail
`{:record_too_large, %{id:, key:, size:}}`) with nothing leased — the record
stays pending for an operator to inspect or cancel by key. The reply is
`ok` carrying the claimed records (`id`, `key`, `payload`, `revision`,
`status`, `claim_id`, `claimed_by`, `lease_until_ms`), oldest first, each
under a fresh lease. Claims expire (default 5 minutes) and expired records
become claimable again — a crashed claimer loses its claim, never the
record. When the server runs no queue, the reply is `error`
(`unsupported`); a dead queue answers `error` (`internal`,
`{:queue_unavailable, ...}`) without affecting unrelated runs.

**`queue_ack`** — blank a claimed record after it was handled. The record is removed; the durable queue log keeps the
tombstone. An unknown or expired `claim_id` answers `error` (`not_found`).

```json
{"v": 1, "type": "queue_ack", "id": "c-10", "claim_id": "clm-1"}
```

**`queue_release`** — return a claim to pending (the client failed before
finishing); the record becomes claimable by the next client.

```json
{"v": 1, "type": "queue_release", "id": "c-11", "claim_id": "clm-1"}
```

**`ops_list`** — bounded read-only operator inspection over the durable
queue plus the operation ledger (`Alto.Ops`).

```json
{"v": 1, "type": "ops_list", "id": "c-12", "limit": 20, "cursor": 0, "filter": "parked"}
```

`limit` (optional, default 20, 1–100), `cursor`
(optional zero-based offset, default 0), and `filter` (optional `all` |
`accepted` | `claimed` | `parked` | `unknown` | `completed`) page through
unified work items. Queue inspection walks bounded 100-record pages, so a
live record beyond the oldest page remains reachable up to the queue's
configured live-record bound. Items carry source, display operation,
semantic `operation_key` where available, generation/revision/attempt
identity, claim correlation, and a bounded reason. `unknown` items always carry
`"safe_to_retry": false` — recovery is reconcile-or-park under the
existing queue/ledger identities, never a blind retry, and this command
exposes no mutating action. The reply is `ok` with `items` plus
`next_cursor` (`null` at the end), encoded against the connection's own
`max_line_bytes` (overflow answers `error` `internal` with nothing
mutated). A dead queue or ledger is surfaced as `error` (`internal`), while
an unconfigured queue+ledger pair answers `error` (`unsupported`); bad
pagination answers `error` (`invalid`).

**`reload`** — request a configuration transition, matching the `:manual`
reload policy.

```json
{"v": 1, "type": "reload", "id": "c-8", "config": "my-alto-config"}
```

`ok` means the request was accepted, not that the transition completed; the
transition — or its failure, retaining the last known good configuration — is
observed through the host's reload events. v1 servers reply `unsupported`.

**`ping`** — intentionally absent. Heartbeats are a transport concern (TCP
keepalive, WebSocket ping frames), not an envelope concern.

## Ordering and delivery guarantees

- **Durable events per run are gapless and monotonically sequenced**, in the
  order the serial host emitted them (one interpreter, one run ⇒ a total order
  per run). A client observes either all durable events up to `seq` n or an
  explicit `overflow` telling it where the gap is. There is no silent gap.
- **Live events are best-effort, unsequenced, at-most-once.** They exist only
  while work is in flight (per `Alto.Event`), so dropping them under pressure
  is correct behavior as long as the client is told (`overflow`,
  `domain: "live"`).
- **`result` is sent exactly once per run** and only after all of that run's
  durable events on the same connection.
- **Command replies are correlated by `id`**; the server may interleave event
  messages between a command and its reply.
- Approval round-trips are the exception to "clients are unprivileged
  observers": an `approval_request` on a client's subscription makes that
  client *eligible to answer*, but the host still enforces the single-decision
  rule — the first valid `approval_response` for a `request_id` wins, later
  ones get `error` (`not_found`).

## Slow clients and backpressure

Backpressure is **user-configurable, per listener component**, selected and
parameterized in the user's compiled Elixir configuration — the same
composition story as executors and approval policies, not a fixed host policy.
A listener configuration names its policy and options, for example:

```elixir
listeners: [{Alto.Listeners.UnixSocket,
             path: "~/.local/state/alto/alto.sock",
             max_line_bytes: 1_048_576,
             per_client: [max_buffer_bytes: 4_000_000,
                          max_buffer_messages: 10_000,
                          live_policy: :drop,
                          durable_policy: :buffer_then_overflow,
                          disconnect_after_overflow: :never]}]
```

Defaults ship with the first implementation; the contract is:

- The core is **never blocked** by a slow client. A stalled client consumes at
  most its configured buffer, then drops (and is told via `overflow`) or is
  disconnected, per its configured policy.
- `durable` events are never silently dropped: dropping a durable event
  requires the `overflow` notice, because durable events are the resync basis.
- A disconnected client loses nothing permanently under v1 semantics except
  what its own `durable_policy` dropped; it can re-`attach` with `from_seq`
  against the retained per-run buffer while the run lives.

## Security

The socket is a **privilege boundary**: whoever can write to it can approve
command and write-tool invocations on runs it can see.

- v1 binds a Unix domain socket inside a `0700` directory, with the socket
  file itself `0600`. On a single-user machine this is the authentication
  boundary, and it is enforced by the filesystem, not by protocol code.
- The optional `auth` token handshake (above) exists for deployments that
  need protection beyond filesystem permissions;
  it is unused by the v1 default configuration.
- `start_run` resolves only server-side trusted compiled configurations by
  name. No message in this protocol carries Elixir code, module names to load,
  or executable strings that the host treats as configuration.
- All client-supplied strings (`task`, `reason`, deny reasons) are bounded by
  the same limits the host already applies to tool arguments and messages;
  the listener validates and rejects before construction.

## Versioning and compatibility

- `v` is in every envelope; a message with an unrecognized major version is
  rejected with `error` (`invalid`), and the connection stays open for the
  client to reconnect with a compatible version.
- The server announces its version and `max_line_bytes` in `hello`; clients
  must adapt before sending anything else.
- Additive changes (new `type` values, new optional fields) increment nothing;
  receivers ignore unknown fields and reject unknown types per-message.
- Durable event sequence numbers are assigned by the configured host store. The
  listener exposes the retained per-run sequence window through `attach` and
  `from_seq`; clients use `overflow` to detect missing history.

## Current implementation notes

The shipped listeners are `Alto.Listeners.UnixSocket` and
`Alto.Listeners.WebServer`; both use the same envelope validation, command
dispatch, bounded notifications, and approval correlation. The built-in GUI is
a client of the WebSocket transport. Queue, session, and operator commands are
available only when the host configures the corresponding stores.

`input` and `reload` are reserved message types and return `unsupported` in v1.
`start_run` rejects inline overrides and resolves only named, server-side
compiled configurations. Clients should use `attach` and `from_seq` with the
retained event window, and treat an `overflow` message as the explicit signal
that replay history is incomplete.
