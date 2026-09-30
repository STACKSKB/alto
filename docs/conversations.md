# Conversation revisions and branches

The `<session>.transcript.json` head is an atomic version-5 manifest containing
revision metadata, a message root/count, and the dispatch fence. Message JSON is
stored once by SHA-256 in `conversations/<session>/objects/message-<hash>.json`.
Immutable reference chunks hold at most 64 message hashes plus a previous-chunk
hash. Revisions share completed chunks; an append writes the new payloads and a
bounded reference tail, not another copy of the conversation. Repeated message
occurrences also share their payload. Reduction or rearrangement of context
shares unchanged message objects. No periodic full transcript copies are needed.

Changed boundaries archive the prior manifest as `revision-N.json`, then commit
the new head with its fence cleared. Objects and the archive are durable before
the atomic head changes. Interrupted publication leaves the prior fence intact;
retries reuse existing objects. An identical save without a fence or metadata
change leaves the revision untouched. Resolving a fence still advances the
revision even when message content is unchanged.

Conversation APIs materialize `"messages"` and return a derived
`"conversation_bytes"` alongside the string-keyed manifest fields. The disk
manifest omits those two fields. `"parent"` and `"dispatch"` use string keys;
`"dispatch"` is nil when no dispatch is outstanding. Pass the returned snapshot
directly as the runner's `:resume` option. A selected revision follows its message
chunks, not a chain of historical transcript deltas. Hashes, node counts, message
structure, and the decoded transcript size are validated before returning it.

`Alto.Session.persist_settled/4` rejects unanswered assistant tool calls, orphan
replies, stale `expected_revision` values, and writes beyond the configured
aggregate storage budget. `max_conversation_bytes` defaults to 128 MB and counts
stored objects and manifests, rather than summing full transcript lengths at
every revision. `:infinity` disables that aggregate cap; the coding profile uses
it. Decoded transcript limits, dispatch fences, and stale-head checks still apply.
The former 20,000-revision ceiling has been replaced with the JSON-safe integer
ceiling, independently of retention. Storage grows with distinct messages and
small changed-boundary manifests, and is not an RSS or filesystem allocation cap.

`conversation_retained_turns` is a runner/configuration, persistence, and fork
option. Its default and the coding profile's selection are `:infinity`: keep all
turns incrementally. Set a positive integer to retain all revision boundaries
within the latest N user turns. This changes rewind/fork availability; it never
removes messages required by the current context. Objects are reclaimed only
when no retained manifest or current head references them. Manifest deletion is
synced before object reclamation. Sessions with finite retention lock readers to
coordinate with collection; unlimited-history viewers remain lock-free normally.

The built-in runner identifies a turn by the root execution identity: one user
message and all subsequent model/tool steps, including checkpoint continuations
and context reduction. Direct persistence callers can pass
`conversation_turn_id: "stable-user-turn-id"` across those boundaries; without
it, newly added user messages infer the turn count. Legacy snapshots have no turn
IDs, so their user-message counts provide the migration fallback.

Version-4 full snapshots remain readable. The next changed save automatically
converts old revisions in place before advancing the head. Conversion preserves
revision numbers, message content, branch provenance, and outstanding fences.
An explicit maintenance command also converts an idle session without advancing
its head:

```sh
mix alto.session.compact SESSION_ID --session-dir /path/to/sessions
# Explicitly opt into keeping only the latest 20 turns:
mix alto.session.compact SESSION_ID --session-dir /path/to/sessions --retained-turns 20
```

The API is `Alto.Session.Conversation.compact/2`. Conversion uses the session lock
and atomically replaces each manifest after its objects are durable, making
interruption restartable. Restart applications built against the old format
before converting their sessions. First-save conversion performs a one-time
scan of old snapshots; later saves write incremental content.

The coding profile also selects `max_steps: :infinity` and
`max_model_requests: :infinity`; the library defaults remain 32 steps and 256
shared model requests. The run deadline, effect budget, cancellation, and
request deadlines still apply. Durable model counters encode the unlimited
policy using their unsigned 64-bit ceiling; restoring a checkpoint or opening
an existing budget account never widens a previously saved finite limit.

Session logs include small `type: "diagnostic"` records for
`provider_attempt_started`, `provider_attempt_finished`, and `provider_retry`.
They record attempt numbers, durations, whether output was delivered, bounded
failure classifications, and retry delays, without request/response bodies or
credentials. They are separate from replayable loop events. A start without a
finish identifies an in-flight or interrupted attempt. Transport timeout records
distinguish provider/network waiting from time spent between requests.

The coding profile allows 30 minutes total per HTTP request, with a two-minute
network-idle timeout. Incoming bytes (including provider keepalives) reset the
idle timer; this is not a two-minute cap on model reasoning. A failed attempt is
retried only before it delivers output. Restart the TUI with the updated profile
to apply these settings; an already running request retains its original options.

The built-in runners opt into these boundaries with `session_history: :settled`
and an enabled session. They persist the initial context and each complete
boundary before the next provider request, fence tool dispatch, and retain
pending provider history before an approval checkpoint. Persistence or dispatch
fence failures stop execution before another effect is dispatched. Terminal
persistence remains visible in `result.persistence`. The library default,
`:completed`, retains its end-of-run persistence behavior; the coding profile
selects `:settled`. Retaining a transcript does not snapshot the workspace.

Custom execution hosts using settled history should follow this order:

1. Persist the initial user context and retain the returned revision.
2. Before dispatching tools or native effects, call
   `Alto.Session.mark_dispatched/3` with stable operation IDs and that revision.
   Additional serial dispatches on the same revision accumulate in the fence.
3. Append all outcomes to the in-memory transcript. Persist the next settled
   boundary with every completed native ID in `resolved_operations`, then retain
   the returned revision.
4. Persist any changed complete boundary before the next provider request.

If the process dies after a dispatch fence but before a matching outcome is
retained, ordinary `Alto.Session.transcript/2` refuses to resume. A terminal
recovery snapshot may contain unanswered provider calls; the normal resume path
closes those calls with explicit `unknown` replies. Native operations require
an explicit retained outcome and `resolved_operations` entry. This prevents a
possibly committed effect from being dispatched again automatically.

`Alto.Session.fork/2` creates a new session from `:latest` or a selected
`revision`. The source head may be fenced, but the selected revision must be a
complete retained boundary. `expected_revision` can fence selection against a
concurrent source update. An optional `summary` is stored as branch provenance.
The new branch receives only the selected messages and byte count. It does not
copy approval grants, checkpoints, pending operations, dispatch fences, event
logs, credentials, or workspace state.

```elixir
{:ok, branch} =
  Alto.Session.fork(source_session, 3,
    expected_revision: 7,
    summary: "Try the smaller migration first",
    session_dir: session_dir
  )

branch.session_id
branch.transcript["messages"]
```

Use `Alto.Session.conversation/3` to inspect one retained revision directly.
The read is bounded and loads only that revision; it does not materialize the
branch ancestry.
