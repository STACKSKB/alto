# Desloppification plan

Alto is at `0.0.1`. Internal formats may break without migration, but preserve
every current capability, including Ripwire, FFF, webhooks, and other features
enabled only by external configuration. Prefer a tiny composable core with
explicit ownership of state and effects. Do not preserve an incidental behavior
merely because a test asserts it.

## Measure the result

The baseline is 40,655 physical lines in production `.ex` files. On
2026-09-25 the count is 33,062, down 7,593 lines (18.7%). Reaching 30% requires
at most 28,458 lines, another 4,604 fewer than today. The 50% stretch target is
20,327 lines. Recount after each coherent change; moving code does not count.
Test files are measured separately.

The largest files are `Alto.TUI.App` (1,718), `Alto.Runner.Execution` (1,323),
`Alto.Queue` (1,031), `Alto.FrontEnd.Registry` (961), `Alto.TUI.View` (890),
`Alto.OperationLog` (848), and `Alto.TUI.Backends.Codex` (842). Size marks a place
to inspect, not a reason to delete safeguards.

## Boundaries established by the audit

- A production clone scan found no identical ten-line flow across files. Core
  and TUI dependency graphs have no dead module cluster: zero-inbound modules
  are application, Mix, configured extension, or backend entry points. Further
  gains must change a complete representation or flow, not delete unused files
  or wrap repeated syntax.
- Queue and operation ledger already share durable file operations and each
  applies the same transition during live writes and replay. Queue business-key
  upsert, source admission, recovery, lease, and tombstone rules are distinct.
  A full-queue rewrite would turn a small lease mutation into an O(queue-size)
  synced write. SQLite is unlikely to remove much code by itself because
  transition and bound checks would remain.
- Session events and conversation revisions support different reads and crash
  guarantees. They now share a session lock; the latest transcript and dispatch
  fence commit atomically in one head, with older revisions archived on the next
  write. A missing head fails closed rather than silently revealing an older
  transcript. Root, parent,
  and child checkpoints already share the portable state codec while retaining
  different authority and resumption rules.
- Runner outcomes differ by dispatch order, cancellation origin, approval
  fencing, provider correlation, and retained child completion. Two complete
  effect-flow audits found no safe local extraction of 100 lines. A replacement
  should simplify the whole flow, not add an outcome adapter around it.
- TUI task entries need per-task state for concurrent streaming and navigation.
  Selection geometry also drives mouse hit tests. Backend-specific Codex and
  native adapters share display projection where their contracts agree; the
  remaining protocol and task-lifecycle branches have different semantics.
- CLI run/serve setup, JSON-RPC framing, provider HTTP/SSE envelopes, and
  workspace path checks have already been consolidated at their shared
  boundaries. Their remaining branches often enforce different authority,
  wire, recovery, or output contracts.

## Next work

1. **Replace a complete state representation.** Trace queue, ledger, session,
   and continuation records from command through replay and recovery. Prototype
   one smaller representation with bounded mutation work and one live/replay
   transition. Corrupt or partial current records must still be observable and
   safe; old pre-release formats need no compatibility path.
2. **Simplify runner effects end to end.** Map the owner and reader of each run
   field and each outcome shape. Try one internal outcome contract spanning
   interpretation, tool completion, event dispatch, and scheduling. Compare the
   complete runner group before keeping it. Preserve append-before-dispatch,
   provider call counts, batch order, cancellation origin, and approval fences.
3. **Simplify TUI state and view together.** Search for state derived twice or
   retained by two owners across app, state, view, and backends. Keep catalog
   recovery, backend selection, approval, clipboard, and selection behavior.
   Reject abstractions that merely move branches or slow interactive input.
4. **Prune tests by behavioral value.** Remove constructor echoes, language or
   library demonstrations, and superseded scenarios covered by a stronger
   integration test. Keep cases that distinguish Alto behavior at malformed
   input, authority, cancellation, concurrency, or corruption boundaries.
   Resource-sensitive integration suites now run serially after intermittent
   full-suite failures; their behavioral assertions remain.

For each pass, name the capability and its desired behavior, make one coherent
edit, run focused tests, formatter, and the affected full suites, then compare
production and test lines. Revert prototypes that add indirection without
reducing the complete flow. The line target does not justify erasing current
capabilities or useful safety checks.
