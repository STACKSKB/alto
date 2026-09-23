# Desloppification plan

Alto is still at `0.0.1`. Internal storage formats may change without migration,
but every current capability remains in scope, including features enabled only
through external configuration. The goal is less production code with clearer
data flow, not a smaller product.

## Measure the result

The starting inventory was 40,655 physical lines in production `.ex` files.
The 2026-09-24 inventory is 33,185 lines, a reduction of 7,470 (18.4%). A 30%
reduction would require at most 28,458 lines, or another 4,727 lines below the
current inventory. Test files are tracked separately and never count toward
that production target. Recount after each coherent change; a moved line is not
a reduction.

The largest remaining files are `Alto.TUI.App` (1,718),
`Alto.Runner.Execution` (1,323), `Alto.Queue` (1,054),
`Alto.FrontEnd.Registry` (961), `Alto.TUI.View` (890),
`Alto.TUI.Backends.Codex` (855), and `Alto.OperationLog` (847). Their size identifies
where to investigate, not what to delete. Focused audits found that many
apparently similar branches differ in authority, cancellation, event ordering,
or recovery guarantees; extracting a helper just to reduce line count can make
those rules harder to see.

The current audit found no removable run-context fields. In particular,
`agent_identity` appears in both the live tool context and the checkpoint state
because checkpoint packets must retain that portable identity without
serializing the tool context's live metadata. The workspace tool tests cover
different host, runner, and approval boundaries even when their inputs look
similar. Git inspection and isolated-workspace Git execution have different
command authority and environment isolation. Keep these boundaries explicit;
the next reduction should come from a complete data-flow redesign, not from
removing one side of such a pair.

The session event log and immutable conversation revisions also serve different
reads; the transcript sidecar is the current revision head, not an obsolete
second copy. The Git workspace's source-tree check, checkout-size check, and
staged-workspace check enforce different safety rules. Provider adapter tests
that look similar inspect different wire contracts. These seams need a new
shared contract to shrink; line-by-line helper extraction would only relocate
policy.

The queue and operation ledger already share durable file operations and each
uses its own transition function for live writes and replay. A queue lease log
stores only the changed lease fields; replacing it with a full record would
increase write volume, and a naive replacement would lose the replay check
that the record already exists.
The Codex and MCP clients likewise share JSON-RPC framing and request tracking.
The next durable-state cut must change the state representation or API shape,
not repeat those existing extractions. A whole-queue snapshot per mutation would
turn a small lease write into a write of the entire bounded queue; prototype a
transactional record store only if it keeps per-mutation work bounded. A
synthetic 10,000-record queue with 2 KiB payloads produced a 20.6 MB whole-state
snapshot. Five synced rewrites took 33–37 ms each, versus under 0.2 ms for a
small synced lease record on the same machine. That rules out whole-state
rewrites as the default mutation path; it is not a production benchmark.
Replacing Queue and OperationLog JSONL with SQLite is also a poor standalone
route to the 30% target. Their 1,913 combined lines contain roughly 420 lines
of clear replay, append, and compaction machinery; a shared transactional
adapter, schema, and bounds handling would consume much of that saving. The
lease, ordering, deduplication, revision, and checkpoint transitions would
remain. Pre-release files would need no migration, but dropping that work does
not make a 1,000-line net cut plausible from these two modules alone.

The TUI now uses one state transition to select the model when a backend is
chosen, whether selection came from opening a task or switching its backend.
The catalog recovery flow warns and asks before replacing invalid data; the
reported on-disk catalog now validates, and the TUI recovery tests pass.

The CLI already shares one-shot and served-run provider/tool/prompt setup;
their remaining approval, persistence, and output paths have different owners.
The front-end registry likewise centralizes run completion, approval cleanup,
and guarded queue calls. Folding its distinct read projections into another
layer would add indirection without a useful reduction.
The consumer's repeated lifecycle and option prose was condensed by 39 lines;
that improves the source inventory but does not shrink executable code.
The shared provider stream envelope now owns the response-byte limit for both
OpenAI-compatible and Anthropic adapters. Decoder-local counters duplicated
that guard and were removed; transport-level bounds still cover SSE, raw JSON,
and HTTP error bodies.
Model-catalog GETs and provider streams now share request-option assembly;
extension options cannot replace their response callbacks or timeout guards.
Network integration tests now run serially after parallel full-suite runs
exposed socket timeouts; their behavioral assertions are unchanged.
The separate Chat loop was a 33-line wrapper around Default. `chat_loop/1`
now configures Default's tool-free mode directly; both full suites pass.
The superseded Chat checkpoint assertions were removed. Codex history and live
completed items now share one entry projection; queue, workspace, and provider
validation also pass through errors without separate forwarding branches.
The operation ledger now performs room planning inside its live/replay transition.
Codex approval methods share one descriptor for labels and response shapes.
Immutable conversation entries use a smaller v2 record: entry IDs are derived
from session and revision, and retries compare decoded entries. A storage-test
audit retained cases that distinguish live state, persisted state, and recovery.
The registry's repeated option and contract prose was condensed by 48 source
lines; this improves navigation but does not reduce executable code.
The catalog now shares capacity-checked append and required-field validation
between projects and tasks, reducing production code by 13 lines. A malformed
task still blocks mutation until the caller explicitly replaces the catalog;
the TUI warning and confirmation path remains covered. CLI key prompting now
states its saved-key, empty-key, and new-key outcomes directly.

The latest runner outcome prototype increased production code by two lines
after formatting and left the branches intact, so it was discarded. A CLI
mode-parameterized setup would likewise add branches around genuinely
different terminal, listener, approval, and onboarding behavior. The TUI
selection renderer cannot simply switch to full cell snapshots: that exports
every cell at drag start and still leaves wide-glyph widths ambiguous. The
large TUI app, provider, and workspace-tool test suites were checked for
tautologies; their similar scenarios cover distinct boundaries. These findings
rule out repeating those local helper extractions as a route to 30%.
Further runner/front-end and TUI audits found no credible 150–200-line local
extraction: root, parent, and child checkpoints already share serialization,
while their remaining branches bind different authority; replacing the TUI's
compact text index with exported cell maps would reintroduce a visible pause
when starting a selection. A clone scan found no other long identical blocks
outside a few small tool wrappers. Larger gains require replacing a whole
representation or dropping an incidental policy, not shuffling helpers.
An additional effect-flow prototype increased code after formatting, and a
TUI navigation prototype did the same; both were reverted. The remaining
model, tool-batch, and scheduler branches account for different event order,
admission, cancellation, and replay responsibilities. Treat a claimed
200-line runner cut as unproven until an end-to-end replacement is smaller.
A new audit measured the runner group at 5,366 lines and found that singleton
and batch outcomes still require distinct dispatch order. TUI modal and
approval consolidation likewise added indirection without a net cut; no edits
were kept from those probes.
The TaskHost lifecycle audit likewise found no safe local cut: host and
subscriber monitors, waiter timers, and capacity cleanup cover separate crash
and cancellation paths. No TaskHost edits were made.
Display output now uses Alto's shared UTF-8 byte truncator. Its previous
grapheme-based clipping could exceed the advertised byte bound; the old
multibyte test had asserted that accidental behavior and now checks the actual
limit. A focused audit of context, codec, loop, and small provider tests found
no full case that merely measured Elixir or library behavior; apparent overlaps
covered different Alto limits or failure boundaries.

## Next passes

1. **Durable state machines.** Compare queue, operation ledger, session, and
   continuation code at the record/transition boundary. Consolidate only
   genuinely shared framing, validation, or atomic persistence. The approved
   native v2 formats need no v1 compatibility path, but corrupt or partially
   written current records must remain observable and safe. A transition
   should have one live and replay implementation. The next prototype must
   replace a complete representation or storage path, not another small
   wrapper around the existing log operations. Do not swap the current logs
   for SQLite solely to improve the source line count.
2. **Runner state and effect flow.** The clearest remaining duplication is the
   untyped outcome protocol between effect interpretation, tool completion,
   event dispatch, and the scheduler: several tuple shapes carry the run,
   events, failure or cancellation, and a pending approval frame. Prototype one
   internal outcome type at that boundary, then compare the entire runner
   module group before adopting it. Preserve append-before-dispatch, provider
   call counts, batch event ordering, approval checkpoint fencing, and the
   origin of cancellation. Map run-context fields to their owners and readers
   as part of that prototype. Reject a design that merely relocates the
   existing map or adds adapters without shrinking the complete flow; a local
   `finish_effect` normalization already failed that test.
3. **TUI state flow.** Keep catalog recovery, backend selection, approval,
   clipboard, and selection capabilities. Look for state that the app stores
   twice or re-derives on every event; move pure decisions to existing state or
   view modules only when the complete TUI group shrinks and event races remain
   testable. Do not collapse view geometry that also controls mouse hit tests
   or text selection.
4. **Other production surfaces.** Audit CLI, listeners, tools, and providers
   for duplicated domain policy. Prefer one validation or display boundary
   where callers really share a contract. Preserve externally configured
   Ripwire, FFF, webhook, and other adapters even if no default config uses them.
5. **Tests.** Remove tests that restate a constructor, the language, or a
   library operation, and duplicate scenarios superseded by a stronger
   integration test. Keep tests that establish Alto's behavior under malformed
   input, cancellation, concurrency, data corruption, or authority checks.
   Review the assertion and the behavior it protects, rather than deleting a
   test solely because it is short.

For each pass: state the capability and the behavior worth retaining, make one
cohesive edit, run focused tests and both full suites when the change crosses
a shared boundary, then compare
production and test line counts. If a proposed abstraction does not improve
readability and reduce net production code, revert it. The 30% figure is a
baseline for the refactor, not a reason to erase useful safeguards or capabilities.
