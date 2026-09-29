# Codebase simplification and performance audit

Audited revision: `4517152`, September 29, 2026. This is an audit, not an
implementation change. Production code and behavior are unchanged.

The strongest remaining opportunities are in rendering, retained ownership,
and synchronous coordination. Several existing bounds limit the size of an
answer but do not limit the work or backing storage required to produce it.
There is no evidence here for a safe, sweeping percentage reduction in SLOC.
The code already shares many of its important execution and persistence paths.

## Scope and baseline

Repository-wide source inventory and pattern/duplication scans covered all
189 production Elixir files. Focused control-flow review covered runner and
child lifecycles, context/checkpoints, storage/recovery, queues/ledger, input,
providers, external processes, tools/workspaces, CLI/listeners/registry, and TUI
state/rendering/search/selection/backends. Examples, package configuration,
the native-loader patch, tests and earlier audit documents supplied context.
Dependencies, generated builds and `.zcode` experiments are excluded from the
production census; third-party internals were not comprehensively audited.

| Source | Files | Physical lines | Nonblank, non-comment lines¹ |
| --- | ---: | ---: | ---: |
| `lib/` | 161 | 25,888 | 21,246 |
| `packages/alto_tui/lib/` | 28 | 8,816 | 7,116 |
| Total | 189 | 34,704 | 28,362 |

¹ Includes documentation strings; this is not a claim of executable SLOC.
The 31,437-line figure in the older simplification plan is historical, not the
current baseline. Moving modules or deleting documentation is not counted as
behavioral simplification in this audit.

Validation on the unchanged production source:

- Core: **1,151 tests, zero failures**.
- TUI: **211 tests, zero failures**, including its native-rendering tests.
- Both used `mix test --preload-modules --seed 337473 --max-cases 8`, sequentially.
- Synthetic probes used Elixir 1.18.3 / OTP 27, 16 normal schedulers, precompiled
  development VMs. No provider requests or user-session reads were made.
- Core `mix xref graph --format stats` reported 161 nodes, 32 compile edges,
  35 export edges, 452 runtime edges and 17 cycles. Filtering cycles with
  `--label compile` reported four cycles containing compile dependencies;
  these are not four compile-only cycles.
- No fresh interactive terminal UX test or production workload profile was run.
  Passing the baseline suite does not certify any proposed refactor.

The [reproduction script](../scripts/codebase_audit_bench.exs) and
[raw samples](measurements/codebase-audit-2026-09-29.json) accompany this report.
Repeated timing probes report five samples, except diff probes with three.
Each sample runs in a fresh worker, with fresh derived caches where relevant;
the VM and native libraries remain warm. Alternatives run in fixed order, so
these are diagnostic comparisons, not randomized performance guarantees.
Backing-binary sizes, serialized weights and process counts are distinguished
from actual RSS. **This audit does not claim a measured reduction in RSS.**

## Priorities

P1 means address first because the path can cause visible lag or loss of visible
history. P2 means a worthwhile optimization with a bounded change and explicit
regression checks. These are implementation priorities, not security ratings.

| ID | Priority | Opportunity | Evidence | Main benefit |
| --- | --- | --- | --- | --- |
| A1 | P1 | Bound Codex's hidden reasoning accumulator | Reproduced visible-entry eviction | UX, memory, CPU |
| A2 | P1 | Render long Markdown tails through a bounded window | Measured | Lag, transient allocations, possible SLOC |
| A3 | P1 | Compact literal transcript indexes | Measured cache rejection/rebuild | Scroll lag, memory |
| A4 | P1 | Bound diff computation as well as preview output | Measured adverse scaling | Tool/approval latency, CPU |
| A5 | P2 | Release internally consumed child results | Reproduced retained hosts | Memory, process count |
| A6 | P2 | Detach small file-tool result slices | Measured backing retention | Binary memory |
| A7 | P2 | Move blocking storage work out of the registry | Reproduced head-of-line blocking | Streaming/approval latency |
| A8 | P2 | Share frame coalescing with the Codex backend | Confirmed separate unbatched path | CPU, lag, simpler presentation flow |
| A9 | P2 | Make delivery demand and in-flight data explicit | Source-confirmed; load profile needed | CPU, mailbox memory |
| A10 | P2 | Reuse saved projections and stream session summaries | Confirmed repeated/full reads | Cold navigation, allocations |
| A11 | P2 | Replace polling joins with event/deadline waits | Confirmed polling loops | CPU, scheduling latency |
| A12 | P2 | Avoid whole-queue scans for bounded requests | Confirmed full materialization | Queue CPU, allocation |
| A13 | P2 | Track transcript changes without repeated whole-history hashes | Confirmed scans; benefit unmeasured | CPU, transient memory |
| A14 | P2 | Reuse event/result byte accounting | Confirmed repeated traversals | Registry CPU |
| A15 | P2 | Move folder discovery off the input callback | Confirmed synchronous filesystem work | Typing responsiveness |

## Findings and implementation constraints

### A1. Hidden Codex reasoning can evict the visible conversation

Sources: [Codex backend](../packages/alto_tui/lib/alto/tui/backends/codex.ex),
lines 605–623; [State](../packages/alto_tui/lib/alto/tui/state.ex), lines 790–817.

Every reasoning delta updates `reasoning_parts`, retains both raw and summary
maps, sorts the chosen parts, and reconstructs the displayed text. Once a
summary exists, raw content is no longer displayed, but it keeps accumulating.
`bounded_value/1` truncates top-level binaries only. The nested map therefore
consumes the entry budget independently of the 64 KB displayed-text bound.

The synthetic notification sequence displayed a 13-byte summary while retaining
1,900,174 serialized bytes. At 2 MB of raw input, the entire entry list became
empty: the newest entry alone exceeded the 2 MB budget, and `bounded_entries/1`
halted before retaining any entry. A conversation with preceding entries can
lose those too through this same path.

Keep a bounded presentation accumulator separate from transcript entries. Stop
retaining raw parts once the summary is authoritative under the existing
selection rule; retain only what can affect the bounded display. Coalesce before
rebuilding the visible string. Preserve raw-only rendering, summary precedence,
part ordering, item completion/replacement and the existing truncation notice.
Do not solve this by shrinking visible history or silently dropping summaries.

Acceptance: replay raw-only, summary-only and interleaved streams beyond 2 MB;
the same bounded text and preceding visible history must survive. Check Unicode
boundaries and different item/content indexes. This is a memory fix with a
direct UX benefit, not merely a smaller data structure.

### A2. A long final Markdown block still renders in full

Sources: [Markdown](../packages/alto_tui/lib/alto/tui/markdown.ex), lines 24–44
and 387–424; [Transcript](../packages/alto_tui/lib/alto/tui/transcript.ex),
lines 137–168.

`tail/3` selects final blocks, but `cached_block/2` materializes all rows of each
selected block before keeping the last screenful. Streaming changes the block's
cache key, so a growing prose/code block repeatedly exports and styles hidden
rows. Native pagination also draws the full source at successive offsets.

| Single prose block, width 84, 40 visible rows | Current tail median | Existing layout + window median |
| --- | ---: | ---: |
| 4 KB | 8.6 ms | 12.3 ms |
| 16 KB | 35.1 ms | 28.0 ms |
| 64 KB | 177.3 ms | 50.5 ms |

Use indexed row measurement and visible-window materialization for large blocks;
keep the cheap small-block path unless measurements justify replacing it.
An incremental parser can reuse completed blocks and rebuild only the open
tail, but Markdown constructs crossing chunk boundaries require care. The
existing two render paths also duplicate heading/code/table presentation: one
canonical block expansion and styling definition could remove real code.

Acceptance: differential row/style comparisons for prose, headings, incomplete
fences, code, tables, tabs, Unicode, blank lines, streaming and resize. Measure
frame latency and native peak memory; the timing alternative above only checked
row counts, not full visual equivalence. It is not yet an approved drop-in fix.

### A3. Literal indexes can be too large to cache

Sources: [Transcript](../packages/alto_tui/lib/alto/tui/transcript.ex), lines
24–61, 87–134 and 188–205;
[Cache](../packages/alto_tui/lib/alto/tui/cache.ex), lines 18–49.

Markdown indexes retain plain rows; literal user/tool indexes retain full
`Line`/`Span` structures for hidden rows. A modest synthetic source of 200
roughly 400-byte user entries produced 20,199 rows and a 6,825,913-byte serialized
index. Charging three times the key/value size rejects it under the default
16 MB cache budget. Calling `viewport/5` then rebuilds the index.

At the default budget, all five samples rejected the index and a subsequent
viewport call had a **51.0 ms median**. A diagnostic 64 MB budget admitted it,
and the same call had a **0.424 ms median**. Raising the default budget is not
the recommendation: it trades more retained memory for latency.

Represent literal plans with compact plain row strings/counts, constructing
styled rows only for the requested window. This unifies their representation
with the purpose of Markdown indexing. Verify the compact index fits the
existing budget and that its source/owner is charged correctly.

There is a smaller adjacent cost: `viewport/5` returns 20,199 rows, mostly blank
placeholders, for 40 visible rows; `Viewport.widgets/1` later slices them away.
The padded value's serialized size was 3.42 MB versus 13.4 KB for the visible
window. These are serialized sizes, not heap or RSS. Carry `{offset, total_rows,
visible_rows}` explicitly through rendering/search/selection to remove that
intermediate representation only if the extra interface complexity is justified.
The measurements show index rejection, rather than padding alone, dominates
this fixture's latency.

Acceptance: cached scrolling under the default budget, very tall literal tools,
search highlights, selection/copy, absolute row coordinates, bottom following,
scrollbars and resize parity. Avoid a cache change that repeatedly evicts the
selected conversation's index to retain cheap subordinate entries.

### A4. A bounded diff preview can require expensive unbounded-in-output work

Sources: [UnifiedDiff](../lib/alto/tools/unified_diff.ex), lines 12–69;
[FileChange](../lib/alto/tools/file_change.ex), lines 8–36;
[EditFile](../lib/alto/tools/edit_file.ex), lines 103–142.

The diff builds `List.myers_difference/2`, all records and all hunks before
`Text.preview/2` limits the output. Completely different 250 / 500 / 1,000-line
inputs took **22.0 / 134.4 / 538.0 ms median**, all to return 128 bytes. The last
fixture is only about 11 KB per input, well below the tool's file-size ceiling.
This is a real CPU/latency risk during preparation, before approval is shown.

First reduce work without changing output: trim identical leading/trailing
regions while preserving hunk context, and avoid materializing unused formatted
hunks. That does not solve worst-case Myers work. A bounded diff algorithm or
explicit large-change fallback needs a separate decision about preview behavior.
Never silently remove the approval preview, replace exact edits with approximate
matching, or describe a fallback as an identical diff.

For ambiguous edits, `:binary.matches/2` also materializes every match although
only eight source locations are displayed. Exact ambiguity counts are current
behavior; preserve those with a counting scan if optimizing that path.

Acceptance: unchanged ordinary patch bytes and no-final-newline handling;
adversarial all-changed/repetitive inputs; frozen approval content and stale-file
rejection. Keep diff generation inside the existing cancellable deadline.

### A5. Internal child consumers omit the new result-release operation

Sources: [Agents](../lib/alto/runner/agents.ex), lines 229–234, 294–320 and
419–463; [TaskHost](../lib/alto/runner/task_host.ex), lines 105–109 and 202–211.

`Agents.finish/3` consumes a child result and clears the handle without releasing
the host. TaskHost retains the full outcome for 60 seconds. A synthetic batch
returned eight outcomes while **all eight completed hosts remained supervised**.
Registry/TUI root consumers already call `Runner.release/1`; the scheduler does
not. Large child messages/events can therefore outlive the scheduler's compact
summary, and successive child batches accumulate completed hosts until expiry.

Release scheduler-owned handles after consuming results, including graceful and
forced-drain paths. Preserve suspended checkpoint ownership and optional custom
runner support. Do not shorten public repeated-`await` lifetime or impose a new
global host cap as a side effect. Add lifecycle coverage proving completed hosts
exit promptly, the summary/checkpoint survives, and custom runners without
`release/1` still work. Measure unique binary retention and RSS separately.

### A6. File-tool slices retain large backing buffers

Sources: [ReadFile](../lib/alto/tools/read_file.ex), lines 65–108;
[SearchFiles](../lib/alto/tools/search_files.ex), lines 124–172;
[Retained](../lib/alto/retained.ex), lines 4–10.

A one-line read returned **141 bytes backed by 999,141 bytes**. Searching the
same file returned a **140-byte match backed by the same-sized file buffer**.
Different files have different buffers; retaining their small results can
consume much more binary memory than serialized-byte limits imply.

Reuse `Retained.detach/1` on result content/snippets at these ownership boundaries.
Do not copy entire files indiscriminately or change line/grapheme/byte semantics.
For line reads, a bounded incremental scan can also avoid reading the entire
1 MB scan allowance just to return the first line; preserve all continuation,
partial-line and scan-limit metadata.

Acceptance: unchanged result maps/content and compact referenced backing sizes
after the worker exits. Cover invalid UTF-8, base64, exact limits and multiline
search. The result proves retention, not a particular RSS saving in real runs.

### A7. Storage calls block unrelated registry work

Source: [Registry](../lib/alto/front_end/registry.ex), lines 290–328, 451–500
and its synchronous ingestion sink at 236–238.

Session listing, event pages, transcript resume reads and queue/ledger operations
execute inside the shared GenServer. A synthetic queue acknowledgement delayed
by 250 ms made an unrelated `:run_ids` call take **251.2 ms**. Actual session
listing can decode 100 logs; transcript reads also acquire a storage lock.
During such work the same registry cannot process other events or approvals.

Start with read-only queries in bounded monitored workers, retaining the caller
and replying through `GenServer.reply/2`. Mutations require explicit sequencing,
completion ownership and uncertain-outcome handling; do not indiscriminately
spawn every request. Reuse the existing external-command separation as a design
reference. Never replace synchronous event backpressure with unbounded casts.

Acceptance: slow store + concurrent streaming/approval/cancellation, worker
failure, caller death, admission limits, shutdown, preserved wire errors and
queue claim/ack ordering. Expected benefit is isolation, not faster disks.

### A8. Codex bypasses the native streaming coalescer

Sources: [App](../packages/alto_tui/lib/alto/tui/app.ex), lines 345–406;
[Codex backend](../packages/alto_tui/lib/alto/tui/backends/codex.ex), lines
241–245 and 599–623.

Native model deltas use a 32 ms / 256-chunk / 8 KiB presentation batch. Codex
notifications return a normal redraw and modify entries for every delta;
reasoning uses `upsert_entry/4`, which re-bounds the entire retained list.
The two backends therefore have substantially different CPU paths for the same
visible streaming interaction.

Translate presentation deltas into one coalescing boundary, retaining backend
run/item identity and flushing before completion, approvals, tool transitions,
input, navigation and cancellation. Do not batch protocol replies or authority
decisions. Count render requests and measure native draw time for both backends
on identical synthetic chunk streams. A1 and A8 should be designed together.

### A9. Delivery bounds stop at the registry, and idle clients poll

Sources: [Connection](../lib/alto/listeners/connection.ex), lines 12–15 and
163–180; [Subscriber](../lib/alto/front_end/registry/subscriber.ex), lines 69–113;
[Registry](../lib/alto/front_end/registry.ex), lines 638–650;
[WebServer](../lib/alto/listeners/web_server.ex), lines 165–196;
[UnixSocket](../lib/alto/listeners/unix_socket.ex), lines 129–141.

Every delivered notification requests another batch of 100. Each connection
also polls every 25 ms. Subscriber accounting subtracts bytes when messages are
sent to the connection process, not when the socket consumes them. Repeated
batch replenishment can transfer retained data into an unaccounted connection
mailbox. This is a source-confirmed accounting gap; a sustained-load RSS effect
was not measured here. At 128 idle connections, the timer design alone permits
5,120 polling callbacks per second, before handling their registry casts.

Use a bounded outstanding batch/credit with replenishment after consumption,
and an empty-to-nonempty wakeup or pending pull to avoid constant idle polling.
Keep domain filters, overflow/gap markers, ordering and stalled-subscriber bounds.
Test a producer faster than a deliberately slow connection and inspect both
registry bytes and recipient mailbox/binary memory. Apply the same ownership
review to Codex's `send/2` fanout and the CLI renderer's asynchronous mailbox
([CLI](../lib/alto/cli.ex), line 372): synchronous observer APIs do not make an
observer's internal asynchronous queue bounded.

### A10. Reuse hydration projections and summarize logs in one streaming fold

Sources: [History](../packages/alto_tui/lib/alto/tui/history.ex), lines 27–55;
[State](../packages/alto_tui/lib/alto/tui/state.ex), lines 783–788;
[Subagents](../packages/alto_tui/lib/alto/tui/subagents.ex), lines 5–34;
[Session](../lib/alto/session.ex), lines 263–279 and 542–560.

Cold hydration loads the parent's SavedSession projection for usage, discards
its other fields, then loads the same parent again during child discovery.
Even a cache hit hashes the consumed prefix. Return/reuse that projection within
one hydration request, while keeping usage publication before queued input can
start a new run. Account for appends between the two existing reads: either
consume the new tail or merge live child updates without losing their events.

Separately, session summaries decode whole logs and retain all records before
filtering starts/completions. Use `LogScan` to fold only first-owner-start,
run/completion counts and last status, validating the same complete input.
This can remove allocation and duplicate aggregation code without a format
change. A disposable validated summary cache is a later optimization.

### A11. Consolidate waiting around notifications and deadlines

Sources: [ToolBatch](../lib/alto/runner/tool_batch.ex), lines 35–91;
[Agents](../lib/alto/runner/agents.ex), lines 20–60;
[Execution](../lib/alto/runner/execution.ex), lines 1094–1144;
[Serial](../lib/alto/runner/serial.ex), lines 81–103.

Tool batches wake every 5 ms; child joins/resume poll every 20 ms; checkpoint
waits poll every 10 ms; manual admission polls every 25 ms. Several loops repeat
budget/cancellation checks and rebuild snapshots while nothing changed.

For task results, receive result/monitor/cancel messages with a timeout at the
nearest actual deadline. For agent/input changes, introduce explicit wakeups
before removing polling. Preserve parent checks before queue refills, slot
parking/reacquisition, source-order results and successful siblings on
cancellation. File-backed cross-VM input still needs a bounded polling mechanism
unless its transport gains notifications; do not silently weaken responsiveness.
This offers genuine control-flow unification, but needs concurrency tests.

### A12. A small queue request still materializes the entire tree

Source: [Queue](../lib/alto/queue.ex), lines 307–318, 356–367, 453–466 and
586–626. Defaults allow 10,000 records.

`ordered_records/1` converts the whole `:gb_trees` value to a list. Claims then
filter everything before taking a bounded prefix; pages discard earlier entries;
key and claim lookups scan all records. Completed-key updates also rebuild a
MapSet of up to 10,000 keys on every settlement.

Start with tree iterators and early termination for pages/claims. Reclamation
of expired leases is a separate full scan and must not be skipped accidentally.
Only add key/claim/due-time indexes if a 10,000-record profile justifies their
maintenance complexity. Update completed membership incrementally alongside
its order. Preserve duplicate-key rules, FIFO/due ordering, byte-fitting prefixes,
replay reconstruction and append-before-publication durability.

### A13. Track transcript revisions internally rather than hashing to detect change

Sources: [History](../lib/alto/runner/execution/history.ex), lines 30–65;
[Execution](../lib/alto/runner/execution.ex), lines 1398–1428;
[Transcript](../lib/alto/runner/execution/transcript.ex), lines 13–20 and 236–244;
[Conversation](../lib/alto/session/conversation.ex), lines 115–157 and 265–289.

Settled-history checks serialize and SHA-256 the full message list, including
unchanged checks. Final-result construction hashes it even when history was
never persisted. Compaction, observation validation, snapshot validation and JSON
encoding add further whole-history passes with distinct purposes.

A runtime message-generation counter plus persisted-generation marker can remove
the change-detection hash. Centralize all message replacement/append/restore
paths so the marker cannot go stale. A smaller first step avoids the final hash
when `history_digest` is nil. Keep persisted hashes, revision CAS, validation and
dispatch fences where they establish integrity; do not conflate them with this
local dirty check. Snapshot/delta storage is a separate high-risk design change,
not a prerequisite for eliminating redundant in-memory work.

### A14. Measure notification and finished-run weights once

Sources: [Registry](../lib/alto/front_end/registry.ex), lines 607–636 and
728–747; [Subscriber](../lib/alto/front_end/registry/subscriber.ex), lines 24–29.

Fanout recalculates `external_size(notification)` for each interested subscriber.
Finishing a run recalculates every retained finished run's weight. Compute the
immutable notification's size once and pass it to enqueue. Record a finished
run's size and update an aggregate on insertion/eviction and any subsequent
change: ingestion currently accepts events even for retained finished runs.
Retain conservative logical accounting, zero budgets, exact overflow behavior
and result delivery before eviction. This saves repeated traversal; no
end-to-end throughput gain is claimed without fanout profiling.

### A15. Folder completion is bounded in output, not input work

Sources: [Folders](../lib/alto/harness/folders.ex), lines 27–58;
[Menu](../packages/alto_tui/lib/alto/tui/menu.ex), lines 94–122.

Each edit can synchronously list the directory, stat every matching candidate,
sort them all, and then show 50. Large or slow-mounted directories can block
typing. Use cancellable background requests with generation tokens, retaining
the latest result while fetching the next one. Compute the common prefix over
all matches and maintain only the first 50 sorted results if replacing the
sort. Arbitrarily stopping at 50 would change tab-completion behavior. Verify
keyboard/mouse completion, hidden directories, tilde paths and folder creation.

## Specific simplifications with a defensible deletion target

These are candidates, not promised line savings. Measure formatted production
lines after implementation and review semantic complexity as well as counts.

| Candidate | Code to remove or unify | Constraint |
| --- | --- | --- |
| Markdown block expansion | Duplicate table expansion at Markdown lines 90–108 and 367–383; duplicated heading/code styling | Preserve all cells, empty records and full/window parity |
| Transcript cache contract | `cached/4` still accepts `{value, rows}` only to discard `rows`; callers compute obsolete row weights | Remove the wrapper payload/count calculations, retain Cache byte accounting |
| ReadFile line scanning | `line_offset/3` and `line_end/3` share newline traversal but differ at EOF | One scanner with explicit EOF result, preserve continuation metadata |
| SavedSession replay callback | `LogScan` calls `replay([line], ...)`, wrapping a single record in a list/reducer | A single-record fold preserves record limits and corruption errors |
| Hydration projection | Repeated parent load plus usage-only wrapper | Preserve publication order and appended-tail visibility (A10) |
| Wait loops | Repeated harvest/check/sleep recursion | Unify only after event and cancellation semantics are explicit (A11) |

An exact-clone scan found no cross-file duplicate block of ten consecutive
nonblank/non-comment lines with more than 220 characters after whitespace
normalization. That is a limited textual check, not proof of no semantic
duplication. The concrete duplicates above are mostly within modules or differ
in names. Large modules such as App and Execution deserve careful ownership
boundaries, but splitting them into more files alone would not simplify them.

## Lower-confidence follow-ups and deliberate non-changes

- Compile-connected cycles are a development-time optimization candidate, not
  evidence of runtime lag. Three reported cycles pass through Budget's
  `@defaults Alto.Config.budget_defaults()`; another passes through Command's
  compile-time argument schema and the reverse `Arguments.schema/1` call to
  `Tool.object_schema/3`. Consider runtime default lookup at construction and
  moving pure schema construction to the lower-level argument module while
  preserving the public delegate. Measure affected-module recompilation before
  and after; do not duplicate defaults or reorganize every runtime cycle.
- Cache keys contain complete source/derived terms and LRU maintenance scans a
  list. Profile hit/miss/key-hash and eviction cost under streaming/search; stable
  owner/revision/width keys may help. Do not replace them with hashes that permit
  stale hits or introduce unbounded ETS ownership. A3 is the demonstrated issue.
- `LogScan` repeatedly scans an unfinished line across 64 KiB chunks. The isolated
  framing probe for 1 / 4 / 8 MB lines took 1.3 / 9.0 / 30.1 ms median, excluding
  JSON decoding. Chunk accumulation plus newline search can reduce repeated work;
  this is lower priority than A1–A7 and must retain torn-tail/hash semantics.
- Queue/ledger replay still reads/splits a whole bounded log (64 MB defaults).
  Consider streaming replay with the existing framing primitive after profiling
  restart peaks. Preserve validation-before-tail-repair and exact record errors.
- Catalog persistence, `flock`, and directory `sync -d` spawn external processes.
  Their cost depends on filesystem and workload. Preserve OS locks, fsync and
  uncertain post-rename errors; do not replace them with a BEAM-only lock or
  acknowledge durable work early to improve benchmark numbers.
- Anthropic text accumulation was explicitly tested: 1,000 / 4,000 / 8,000
  64-byte deltas took 2.6 / 10.3 / 21.1 ms median. This fixture scales roughly
  linearly. A textual `<>` scan is not evidence of quadratic copying on BEAM.
  No provider-state abstraction or blanket iodata rewrite is justified by it.
- Retain the existing shared Tool arguments, command/process host, HTTP envelope,
  retained-cell lifecycle, checkpoint capture/restore, and listener dispatch.
  Native/Codex semantics, exact saved terms versus portable wire values, and
  write/edit approval rules are intentionally different. Forced unification
  risks adapters and regressions rather than useful deletion.
- Keep native-grid explicit release, the atomic NIF loader patch, four-worker
  indexing, and the existing cache bounds. Earlier audits already rejected
  lower indexing concurrency and smaller scratch grids on performance evidence.
  No new dependency upgrade or allocator/scheduler flag change is recommended.
- Native allocator/syntax-table RSS remains a separate profiling task. The
  existing RSS audit documents that lower logical retention does not reliably
  lower final-cycle RSS. Measure repeated whole-process cycles and external child
  RSS before making further resident-memory claims.

## Suggested implementation sequence and acceptance

1. **Small ownership fixes:** A5 and A6, plus the no-history final-hash fast path
   in A13. These have narrow correctness surfaces. Take a new memory baseline.
2. **Rendering and Codex state:** A1, A2, A3 and A8 together as separately
   reviewable changes. First use the existing renderer parity fixtures; then run
   a real terminal check for streaming, navigation, search, selection/copy,
   resizing, approvals and queued input.
3. **Coordination and delivery:** A7, A9 and A11. Exercise slow stores/clients,
   cancellation, owner death, replay gaps, checkpoint/resume and successful sibling
   retention. Keep all admission and durability guarantees.
4. **Scaling and cleanup:** A4, A10, A12, A14, A15 and the small simplifications.
   Require measured gains on the triggering workload. A4's worst-case diff
   fallback requires explicit UX equivalence review before adoption.

For each accepted change, report production implementation/documentation line
counts separately; cold and warm frame latency; callback/render counts;
reductions/CPU under idle and load; live binary/native retention; peak and
steady-state RSS across repeated cycles. Do not sum shared cache weights into an
RSS prediction. Run test VMs sequentially to avoid the previously documented
code-loader timing interference.

Reproduce the included probes:

```sh
mix run --no-compile scripts/codebase_audit_bench.exs core
```

From `packages/alto_tui`:

```sh
mix run --no-compile ../../scripts/codebase_audit_bench.exs tui
```

Compile the respective development project first if its build is absent or
stale. The diagnostic 64 MB cache run is confined to a probe worker and does
not change application defaults. The probes intentionally retain synthetic
completed child hosts until their fresh VM exits.
