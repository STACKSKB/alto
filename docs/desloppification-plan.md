# Desloppification

Alto is at `0.0.1`. Preserve capabilities; internal APIs, formats, sequencing
and error details may change without migrations. Prefer Elixir, OTP and existing
libraries. Add no dependencies for this cleanup. Moving code or compressing
formatting does not count as simplification.

## Measurement

The fixed baseline is **40,655** physical production `.ex` lines under `lib/`
and `packages/alto_tui/lib/`. The 30% target is **at most 28,458**.

Current: **33,043 lines**, an **18.7% reduction**, with **4,585 lines remaining**.
Added functionality does not reset the baseline. Source-documentation reductions
are included in the physical count; tests, Markdown, examples, dependencies and
generated output are excluded. Report implementation and documentation savings
separately rather than treating removed prose as simplified behavior.

```sh
git ls-files -z 'lib/*.ex' 'packages/alto_tui/lib/*.ex' |
  xargs -0 -I{} sh -c 'test ! -f "$1" || wc -l "$1"' sh {} |
  awk '{sum += $1} END {print sum}'
```

## Current architecture

The substantive consolidations are grouped here; Git history holds individual
changes and historical test counts. Contracts belong in the component guides.

- Execution owns authority, budgets and input once, projecting tool contexts at
  invocation. Tool and agent operations share dispatch fencing, bounded outcomes
  and completion. Checkpoint variants share capture and restore; workspace
  actions update one retained resource under revision fencing.
- `Agents` owns synchronous and asynchronous child startup, subscriptions,
  completion and shutdown. Synchronous batches use scoped schedulers and raw
  source-ordered outcomes; parent checks authorize queue refills. Shutdown drains
  subscriptions before forced termination. See [runners](runners.md) and
  [subagents](subagents.md).
- MCP and Codex share the JSON-RPC process host, framing, request admission and
  startup handling. Private Codex clients monitor their tool owner and close the
  entire process group on tool exit, including during initialization. They no
  longer need a guardian or a `turn/interrupt` handshake before shutdown.
- Registry, queue and ledger callers use one request contract each. Consumer
  settlement happens at one boundary after durable work. Snapshot persistence
  shares bounded reads, locked updates and atomic replacement. Queue records
  have one representation across storage, replay and reads.
- File writes and edits share preparation and commit. File/diff previews share
  bounded iodata traversal. Command output retains one bounded first/last buffer.
  Context policies and tokenizer adapters use existing tuple/function contracts.
  Seventeen tools share argument contracts for schema projection, defaults and
  validation; domain callbacks retain file freezing, Git confinement and authority.
- TUI state uses canonical catalog, task and run data. Rendering shares per-frame
  projections; backend event and approval flows reuse existing handlers. User
  and agent messages share input channels, receipts and validation.

Folder entry now uses the existing text form, and folder suggestions use the
existing searchable menu. The standalone folder picker and its separate rendering,
geometry, input and mouse-selection paths are removed. Ctrl+O opens suggestions;
selection returns to the typed form, Enter opens it, Tab completes paths, and
Ctrl+N creates folders. Shared menu hit testing accounts for scrolling and excludes
border cells. Configuration no longer maintains a duplicate option registry:
trusted keyword options are validated by their consumers, with TUI constraints
owned by TUI State. Operator inspection joins projected queue/ledger records
instead of rebuilding flattened aliases; payloads and checkpoint contents remain
private. These contract and workflow changes remove **293 physical production
lines**: 232 code/typespec lines, 26 blank lines and 35 documentation/comment lines.
Constructor-echo tests were removed; integration coverage exercises configured
execution, inspection privacy, folder creation/completion and scrolled mouse input.

Completed runs now carry `status` and `reason` directly on `Runner.Result`.
Sessions, child summaries, CLI/TUI completion and subscriber notifications consume
that record instead of unpacking and rebuilding success/error tuples. Bounded
child projections retain accounting and effect `verdict`; subscriber projections
exclude transcripts and events. Session audit records use `status`, and listings
use `last_status`. These API and record changes have no compatibility adapters.
The TUI also removes its obsolete run-monitor completion/cleanup path; completion
subscriptions already handle worker failure. This pass removes **70 net production
lines**: 69 implementation lines and one source documentation/comment line.
A workspace-retention prototype was discarded because it grew after formatting.
The canonical-result change passes all 1,091 core tests and 144 TUI tests; coverage
includes malformed restored child summaries, nested tuple errors with successful
siblings, cancellation, suspension and real TUI worker-crash recovery.

Budget accounts and child continuations now share one generation-bound retained
record, storage envelope, validated snapshot and lifecycle. The change removes
**56 net production lines**: 58 implementation lines removed, with two source
documentation lines added. Domain callbacks retain counter limits, child grants,
approvals and join eligibility. Ledger mutations fence both generation and revision,
preventing stale handles from modifying a reused key with a colliding revision.
The storage format and handle types change without migrations. Generated-schema
metadata assertions were pruned while runtime validation coverage remains.

Clipboard reads and writes now reuse supervised invocation, removing both local
task-wait/shutdown paths and **28 implementation lines**. Private stdin files,
desktop helper selection, timeout handling and OSC 52 fallback are retained;
all 144 TUI tests pass. No source documentation was removed in this pass.

The preceding cleanup removed **67 net production lines** across twelve modules:
69 implementation lines removed, with two net documentation/typespec lines added.
Supervised calls return callback values directly and share failure/cancellation
tags, removing repeated unwrapping across execution, consumers and front ends.
Cancellation still preserves completed siblings and bypasses false tool-result
commitments; mutation uncertainty remains classified at dispatch boundaries.

The canonical-record cleanup removed 65 net production lines: 54 implementation lines
and 11 lines from the now string-keyed snapshot typespec. Conversation storage,
revision reads, forks and resume now share the same JSON-shaped record instead
of carrying paired storage/public representations. Provider profiles normalize
structs, maps and keywords through one path. The conversation format is version
4; old formats are rejected without migration.
The tool-contract pass removed 106 production lines. Input ownership
and ledger transition composition removed 26 and 77 lines in preceding passes.
The separately requested worktree feature added 426 production lines, included
in the current total without resetting the baseline.
No dependency or migration was introduced. Earlier cleanup introduced one SSE
library to replace two parsers; subsequent passes have added no dependencies.

## Remaining work

The target is not met. Prioritize deleting duplicate workflows through functional
composition and canonical state. The “Analyze code duplication” findings have
been checked against callers; reject extractions that add adapters without
removing implementation. Recent CLI/menu/selection reviews found no substantial
remaining duplication; merely wrapping their distinct flows is not progress.
Provider response/state prototypes were discarded: after formatting, they
removed only five lines while adding a reconstruction step. Workspace lifecycle
and listener audits likewise found no large duplicate flow beyond the existing
shared storage, HTTP and connection mechanisms.

Preserve append-before-dispatch durability, single-use grants, bounded retention,
frozen approval values, and the distinction between rejection and uncertain
mutation. Exact session payloads and portable wire projections serve different
purposes. Terminal selection retains raw text capture because exporting cell
maps slowed mouse-down handling. Remove constructor-echo tests, while retaining
failure, concurrency, recovery, authority and user-interaction coverage.

## Harness fixes and verification

Tuple errors now retain the surrounding JSON result shape, including successful
siblings' output, run IDs and usage. Spawn/start schemas use the resolved child
limit; tests cover limits 1, 4 and 12, plus acceptance/rejection of five children.
Codex follow-ups retain model/effort selection. Restored mailboxes reject duplicate
IDs, malformed messages and missing queued receipts.

The current code passes **1,091 core tests** and **143 TUI tests** with application
modules preloaded. The direct-call consolidation retains retry, cancellation,
uncertain-outcome and successful-sibling coverage, adding reducer crash and
cancellation regressions. The canonical-record change preserves coverage for forks,
resume, crash recovery, frozen dispatches, bounds and provider normalization.
Its byte-accounting regression checks the stored bytes and immutable revision;
corruption cases cover missing dispatch/counter fields and mismatched fences.
Ordinary full-suite runs hit tool-start timing assertions on both the refactor
and unchanged HEAD; captured workers were waiting in BEAM's code loader. No
assertion timeout or production startup behavior was changed. Reproduce the
verified run with:

```sh
mix test --preload-modules --seed 337473 --max-cases 8
```

A differential check matched **90,000 ledger transitions** for acceptance,
revision fencing and all public recovery fields. The input cleanup also passed
43 focused ownership, transport and messaging tests before integration. Formatting
and diff checks pass. Run test VMs sequentially; concurrent VMs caused timing failures.

Earlier differential checks matched 12,962 valid UTF-8 diff previews, 42,480 prose
projections, 8,721 protocol decodes and 100,000 subscriber transitions. Converted
registry and ledger calls were compared against their prior arguments before
running the suites. Terminal selection remains approximately 1 ms at 200×60.

Real-key PTY tests cover Ctrl+G/Q and Ctrl+C. The documented
`mix alto.tui --config ../../alto.agentic.exs` emits terminal mode resets on
normal exit. GNU Screen/GNOME Terminal mouse leakage was not reproduced;
no speculative workaround was retained.
