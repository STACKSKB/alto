# Conversation revisions and branches

Alto sessions keep two forms of conversation state. The existing
`<session>.transcript.json` sidecar is the fast resume head. Each update also
creates an immutable revision under `conversations/<session>/`, linked to the
revision it followed. Legacy transcript sidecars remain readable and become an
ordinary parent the next time the session advances.

`Alto.Session.persist_settled/4` records a complete provider-history boundary.
It rejects unanswered assistant tool calls, orphan tool replies, stale
`expected_revision` values, and writes that would exceed
`max_conversation_bytes`. The default aggregate limit is 128 MB per session;
the store reports `:conversation_storage_limit` and never silently removes an
older revision or branch.

Execution hosts using settled history should follow this order:

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
  Alto.Session.fork(source_session,
    revision: 3,
    expected_revision: 7,
    summary: "Try the smaller migration first",
    session_dir: session_dir
  )

branch.session_id
branch.transcript.messages
```

Use `Alto.Session.conversation/3` to inspect one retained revision directly.
The read is bounded and loads only that revision; it does not materialize the
branch ancestry.
