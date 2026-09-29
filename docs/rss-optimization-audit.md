# Alto and TUI RSS optimization audit

Date: September 29, 2026. Scope: the current working tree, including the recent
performance fixes. The original analysis is preserved below; the implementation follow-up records the fixes now applied.

## Implementation follow-up

The prioritized retention fixes are implemented:

- Header parsing copies only the first JSONL line before decoding. Long-lived
  display/cache values selectively detach disproportionate backing binaries.
- Search scans incrementally into at most 1,000 compact matches; contextual
  excerpts are constructed for result display. Counts show `1000+` on truncation.
  Closing search explicitly drops all search-owned caches.
- Event queues enforce count and serialized-byte bounds. The registry additionally
  limits finished-run and aggregate subscriber bytes. Result delivery happens
  before eviction. Supporting runner hosts expose explicit release after consuming
  their result, used by the TUI and registry, while repeated await retains its
  existing lifetime for other callers.
- Derived TUI caches share a configurable weighted budget and task ownership.
  History entries and child activity share an inactive-history byte budget, with
  active/selected/queued tasks protected. Eviction releases an owner's derived
  caches. These are logical budgets, not promises of a fixed RSS ceiling.
- Saved activity replay hashes the old prefix in chunks and decodes complete
  appended lines through one file descriptor. Event pagination also scans in
  bounded chunks, retains only the requested page and validates the entire log.
- Selection materialization captures only the current transcript/search view;
  visited selection rows retain text/ranges without paint metadata. Markdown
  metrics scratch buffers are capped at 32,768 cells rather than 131,072.

Runtime scheduler/allocator settings and native syntax tables are unchanged.
Checkpoint and queue storage formats are unchanged. Direct callers that retain
large full results still own that memory until release/TTL; protected active TUI
work can exceed the inactive-history budget. Large individual log lines remain
bounded by the existing log ceiling. These are explicit remaining bounds rather
than attempted global heap caps.

## Post-fix validation

Core suite: **1,151 tests, zero failures**; TUI suite: **210 tests, zero
failures**. The final registry accounting adjustment also passed all 27 registry
tests. Actual Xvfb/xterm navigation showed initial click feedback in 24–37 ms,
cold transcript display in 332–347 ms, and cached conversation switches in
44–48 ms. Historical indexing took 164 ms; the subsequent scroll took 19 ms.
Markdown headings/emphasis and truncated tool activity were visually checked.

Fresh, precompiled development VMs ran the synthetic probes sequentially.
[Raw post-fix samples](measurements/rss-2026-09-29-after.json) record:

| Workload | Before | After |
| --- | ---: | ---: |
| 1,000 unique 64 KB events, global binary memory after worker GC | 65.49 MiB | 8.64 MiB |
| Same event workload, process RSS | 243.63 MiB | 148.63 MiB |
| 120-byte cached header title, backing allocation | 32,768 bytes | 352 bytes |
| 180-byte displayed message, backing allocation | 4,200,453 bytes | 180 bytes |
| Dense search worker memory | 3.93 MiB | 0.22 MiB |
| 12-conversation renderer workload, RSS after GC | 192.72 MiB | 203.04 MiB |

The renderer workload did **not** improve total RSS in this sample; peak RSS
also rose from 217.61 to 231.62 MiB. The new budgets bound retained cache weight,
not native/allocator residency. After the worker exited, RSS remained 198.96 MiB
while BEAM memory returned to 61.84 MiB. Native allocator profiling and repeated
steady-state cycles remain follow-up work, rather than an asserted memory win.
The hydration probe's global binary counter initially includes other process
allocations; backing-allocation measurements directly verify display detachment.

## Native lifecycle follow-up: accepted and rejected experiments

The next implementation releases a replaced native scratch terminal immediately
through `ExRatatui.safe_restore_terminal/1`. The native implementation takes and
drops the test backend without changing the real terminal mode. Previously a
small BEAM resource handle could keep a large obsolete native grid alive until
GC. Scratch grids for Markdown, wrapping and selection have separate owners;
unchanged dimensions still reuse the existing resource.

Validation used three fresh, precompiled VMs for each baseline/candidate and each
workload, with three cycles of 12 conversations per VM. Standard conversations
have 120 distinct entries at width 84; long-block conversations have 40 entries
at width 41. Each indexed viewport also renders its visible window and tail.
Reported time is the pooled median of those operations; memory is the median of
per-VM peaks or final-cycle samples. This is local experimental evidence, not a
production percentile guarantee.

| Workload / metric | Baseline | Immediate native release |
| --- | ---: | ---: |
| Standard: peak RSS | 227.7 MiB | 215.5 MiB |
| Standard: final-cycle RSS | 194.8 MiB | 204.2 MiB |
| Standard: index + window + tail | 157.4 ms | 115.1 ms |
| Long blocks: peak RSS | 236.9 MiB | 205.7 MiB |
| Long blocks: final-cycle RSS | 197.0 MiB | 195.2 MiB |
| Long blocks: index + window + tail | 116.7 ms | 100.2 ms |

The full TUI suite passed **211 tests**. A native Xvfb/xterm check showed
cold transcript display in 219–256 ms, cached switches in 26–61 ms, first
historical indexing in 222 ms, and subsequent scrolling in 19 ms. Rendering
remained correct. These single navigation samples are functional smoke checks,
not controlled latency comparisons; the repeated synthetic results above are
the performance evidence.

**Kept:** explicit native-grid release. It improves transient memory and latency,
with a regression test proving the old grid closes before GC and another owner's
grid remains usable. Standard final-cycle RSS increased by 9.4 MiB despite lower
peak RSS; this is not a claim of a universal reduction in resident memory.

**Rejected:** reducing indexing concurrency from four workers to two. In the
initial paired probe, second/third cycles took 3.15/2.96 seconds versus
1.72/1.76 seconds, while final RSS was effectively unchanged. Four workers remain.

**Not kept:** reducing the Markdown scratch ceiling from 32,768 to 8,192 cells.
The standard fixture rarely reaches that ceiling and cannot demonstrate a win.
A long-block trial with both smaller scratch and native release had a median
operation around 150 ms, versus 100 ms across the release-only repetitions.
It adds native pagination/reparsing work; the trial did not justify that tradeoff.
The 32,768-cell ceiling remains. Scheduler counts and allocator flags are unchanged.

Reproduce with `scripts/tui_memory_cycles_bench.exs LABEL [long]` from the TUI
package via `mix run --no-compile`. The script records RSS, PSS, anonymous resident
memory, BEAM/binary/process memory and cache weight. Raw measurements, including
rejected trials, are in
[the native lifecycle results](measurements/rss-native-lifecycle-2026-09-29.json).

## Main conclusion

Fix ownership and retention before tuning the runtime. There are confirmed cases
where a tiny retained string keeps an entire decoded file/read buffer alive, and
where search expands a small source into thousands of heavyweight match maps.
Harness event and completed-result retention needs aggregate byte budgets as well
as count limits. TUI caches need coordinated eviction and memory accounting.

The indexed renderer already materially reduces live heap versus full styled
rendering. Reverting it would lose both latency and memory benefits on distinct
content. Its parallel construction and multiple cache layers still increase peak
RSS and leave room for improvement.

## Measurement method and limits

The reproducible probe is [scripts/rss_bench.exs](../scripts/rss_bench.exs).
Raw synthetic results are in [measurements/rss-2026-09-29.json](measurements/rss-2026-09-29.json).
All probes were offline and used synthetic data; temporary session files were
removed. No provider calls or user-session mutations were made.

Environment: Linux, Elixir 1.18.3, OTP 27, ordinarily 16 normal and 16 dirty CPU
schedulers. These are fresh **Mix development VMs**, not a packaged production
release, and do not include external model/server/command processes or a terminal
emulator. Boot RSS includes Mix/compiler/application overhead. Some probes ran
concurrently in separate VMs; numbers are representative samples, not percentiles.

Measurements distinguish Linux RSS/high-water RSS, `:erlang.memory/0`, worker heap,
referenced binary count, and mailbox length. Samples before/after an explicit
worker GC separate live retention from garbage. Per-cache `:erts_debug.size/1`
measurements count reachable heap words, exclude off-heap binary/native payloads,
and **must not be added together**: different roots can share terms.

RSS is not equal to BEAM's allocation counters. Freed data can leave allocator
capacity resident; native Rust allocations and loaded code also contribute.
The residual RSS minus BEAM total is not an exact NIF-memory measurement. Shared
binaries are reference-counted; a slice can retain a larger backing allocation.
See the [OTP 27 memory API](https://www.erlang.org/docs/27/apps/erts/erlang.html#memory/0)
and [OTP binary memory model](https://www.erlang.org/documentation/doc-14/doc/efficiency_guide/binaryhandling.html).

| Synthetic workload | Observed result |
| --- | --- |
| Core boot | 111.7 MiB RSS; 59.5 MiB BEAM total |
| 1,000 distinct 64 KB tool-event payloads, after GC | 243.6 MiB RSS; 65.5 MiB global binary memory versus 1.2 MiB at boot |
| Release those events and GC | 126.6 MiB RSS; 1.0 MiB binaries |
| One distinct-content conversation, indexed viewport | 143.4 MiB RSS; 0.93 MiB worker heap after GC |
| Same conversation, full styled document, separate VM | 166.2 MiB RSS; 6.36 MiB worker heap after GC |
| 12 conversations with bounded layout/tail caches | 192.7 MiB RSS; sampled high water 217.6 MiB |
| Drop UI state but retain process-local renderer caches | 192.7 MiB RSS; 3.93 MiB worker heap; 5.06 MiB global binaries |
| Drop all caches and exit worker | 180.7 MiB RSS; 60.6 MiB BEAM total; worker gone |
| 20,000-byte text with 10,000 search matches | 3.93 MiB worker heap after GC; match cache reachable heap 2.67 MiB |
| Bounded display of a 4.2 MB saved transcript | 180-byte assistant string references 4,200,453-byte backing binary |
| Copy retained display strings | Backing becomes 180 bytes; global binary memory drops about 4 MiB after GC |
| 200 cached session headers | Each 120-byte task retains a 32,768-byte read buffer; about 6.25 MiB combined |

The event probe exercises the retention structure at its default count limit; it
is not a claim that every ordinary run produces 1,000 maximum-size tool results.
The indexed/full comparison uses 120 distinct assistant entries, each containing
45 repeated formatted sentences. Identical text across entries can share caches
much more effectively and gives a different result.

## Prioritized changes

### 1. Detach small persisted strings at ownership boundaries — highest confidence

**Confirmed in both harness discovery and TUI hydration.**

- `Session.Children.header/1` reads 32 KiB, splits the first line and JSON-decodes
  it. A cached 120-byte task string retains the entire read. `ChildIndex` retains
  up to 4,096 headers in each of four directories. If every file has a full read
  buffer and a retained slice, that is up to **128 MiB per directory** of backing
  data, or **512 MiB across four directories**, before metadata. This is a
  theoretical cold-read ceiling, not a measurement of the user's directory.
- `State.load_session_entries/2` fetches and decodes a transcript, then keeps a
  bounded presentation. The synthetic result retained 8,000 + 180 bytes of visible
  strings, but the second string still referenced the original 4.2 MB JSON input.
  Logical display-byte accounting therefore understates retained memory.
- Apply the same inspection to loaded child-cache records, saved activity tails,
  search snippets and wrapped-row strings. Persisted cache reloads may share one
  cache-file binary; count unique backing allocations rather than each reference.

**Proposal:** copy the first header line before decoding it, or explicitly retain
only compact detached header fields. At long-lived presentation/cache boundaries,
selectively `:binary.copy/1` strings whose backing allocation is much larger than
what is retained. Use a minimum backing size plus a ratio threshold; do not copy
all model/transcript binaries blindly. The same source shared by many useful
slices can be cheaper than separate copies.

**Acceptance:** the header probe no longer pins 32 KiB per title, and the hydration
probe retains a compact binary for the 180-byte answer after the loader exits.
Navigation latency must remain within its current range. Immediate RSS shrinkage
is not guaranteed even when live binary memory is released.

### 2. Bound and compact search results — highest risk of amplification

`Search.find/2` eagerly runs `Regex.scan`, then allocates a map and contextual
excerpts for every occurrence. There is no match-count or byte ceiling.
`Search.close/1` clears state but leaves process-dictionary match/projection/render
caches alive until overwritten. A 20 KB repeated text already generated a 3.93 MiB
worker heap. The larger 2 MB display allowance must not be assumed to bound this
expansion to 2 MB. Full search projection adds further row/match structures.

**Proposal:** retain compact `{entry, start, length}` offsets; materialize excerpts
only for visible result rows. Scan incrementally so the temporary regex result
list is also bounded. Page dense matches, or explicitly display a capped count
and continuation. Clear the three search caches on close/task invalidation.
Preserve exact source offsets and Unicode behavior.

**Acceptance:** memory scales with source plus a fixed result-page budget, rather
than with hundreds of bytes per occurrence; search cancellation releases its
owned structures. Test dense matches at the maximum display budget.

### 3. Add aggregate event/result budgets in the harness

`Execution.Events` and `FrontEnd.Registry` retain 1,000 events by count. The queue
change removed list-scanning overhead but did not cap their payload bytes.
`Result` also contains messages, events, loop state and context observations.
The registry retains up to 100 finished runs; `TaskHost` keeps completed results
for 60 seconds. The supervisor has no separate completed-host byte ceiling.
The registry's 32-active-run cap does not apply to every direct runner user.

The queue probe retained roughly 64 MiB in binaries with only about 0.22 MiB of
worker heap. Checking process heap size alone would miss the dominant allocation.
Large reference-counted binaries may be shared across owners, so multiplying
result, queue and host sizes blindly would overstate physical memory. Different
runs' payloads, however, usually cannot share those backing allocations.

**Proposal:** enforce count **and** byte limits for event replay, then a global
finished-result budget with LRU/TTL eviction. Where durable session replay is
available, retain compact event descriptors/previews and load full data on demand.
Add an explicit host-result release/ack or configurable retention duration rather
than changing `await` semantics silently. Preserve replay-gap reporting,
`events_dropped`, checkpoint integrity and consumer access to required outcomes.

Subscribers already have count and byte limits, but the 8 MB default is per
subscriber and the default maximum is 128 subscribers. Add a registry-wide budget;
1,024 MB of configured individual allowances is not an acceptable assumption of
small aggregate memory. Shared notifications mean this is not an RSS prediction.

### 4. Coordinate and byte-budget TUI caches

Current bounds are separate: 12 inactive/task-cache slots, 2 MB logical entries
per task, four transcript indexes, 512 entry renderings, 24,000 styled rows per
render-cache category, 256 Markdown plans, four wrapped documents, 512 wrapping
chunks, plus search and selection resources. Active tasks/queued input are
protected and can exceed the nominal task-cache count. Child activity has its own
256-agent cap and bounded text fields, outside the entry budget.

`Transcript.index/3` currently charges **entry count** against a variable called
`rows`; it intentionally keeps huge indexes cached, but it is not a memory bound.
Keys contain source entries/text; values retain source blocks and derived plain
rows. Dropping `State.entries` does not invalidate these process-dictionary roots.
The 12-document probe demonstrates that independent retention.

**Proposal:** one owner-aware cache budget keyed by task/revision/width and render
mode. Keep the current visible tail hot; evict inactive derived representations
before source entries. Estimate bytes at insertion, not on every token/frame.
Count source ownership separately from derived rows, and detach disproportionate
backing binaries. Clear all related keys when a task/revision is evicted.
Bound plain-index bytes and styled spans rather than only rows: one heavily styled
row can cost much more than a plain one.

Avoid jumping directly to ETS: it provides shared ownership, but copied terms,
lookup overhead and additional lifetime complexity can offset the gain. First
make the current process-local ownership and budgets explicit.

### 5. Reduce transient replay/render peaks without undoing responsiveness

- `SavedSession.load/2` reads up to 16 MB, hashes the old prefix, splits appended
  lines and reduces records. Incremental decoding reduces CPU but still holds the
  raw bounded file. Stream prefix hashing and complete-line tail decoding through
  one descriptor, preserving rewrite/truncation detection and torn-tail handling.
- Session event pagination currently calls `Session.read/2`, decoding the whole
  bounded log before selecting a page. Stream ordinals/filtering into a bounded
  result page. Queue/ledger snapshot replay and checkpoint serialization also
  deserve allocation profiling under their larger configured file limits.
- Index construction uses four short-lived workers. Source binaries can be shared,
  but compound plans cross process boundaries and each worker owns native scratch
  buffers. Benchmark a two-worker or memory-budgeted pool against first-scroll
  latency; avoid serializing all work just to lower RSS.
- Markdown measurement buffers can contain up to 131,072 cells. Native terminal
  resources cached by dimensions are replaced and then rely on GC for reclamation.
  Use bounded reusable scratch dimensions and explicit close where the native API
  permits it. Keep styled export restricted to visible windows.
- Selection stores visited rows and a materialization callback. That callback
  closes over the full `state`, including other cached tasks and prior selection.
  Capture only the selected immutable entries/query/layout context, and retain
  compact selected text rather than per-row paint metadata for long drags.

### 6. Tune baseline/native allocation only after retention fixes

First syntax highlighting raised RSS by about 14 MiB in the unique-content probe,
while BEAM total rose by less than 1 MiB. The dependency loads syntect syntax/theme
sets in process-lifetime Rust `OnceLock`s. This supports investigating a native
baseline cost, but the entire RSS delta cannot be attributed to those sets without
native allocator profiling.

With `+S 4:4 +SDcpu 2`, the unique 12-conversation probe used 169.1 MiB RSS versus
192.7 MiB with 16/16 schedulers; peak RSS was 195.9 versus 217.6 MiB. This single
sample is a possible compact-terminal profile, **not** a recommended global
default. It reduces scheduling capacity and may harm concurrent harness work.
Measure cold startup and throughput in the actual packaged runtime first.

After every worker/cache was released, RSS remained elevated while BEAM total
returned close to baseline. This is consistent with allocator/native high-water
retention, not proof of a live-object leak. Before allocator flags, collect
`/proc/<pid>/smaps_rollup`, ERTS allocator block/carrier usage and native allocation
profiles on repeated steady-state cycles. Check for a plateau versus monotonic
growth. Do not add periodic full-VM GC, `malloc_trim`, or aggressive heap caps as
an initial fix; they can trade the memory symptom for UI pauses or killed work.

## Suggested implementation order and validation

1. Detach oversized backing binaries at header/display ownership boundaries.
2. Compact/page search matches and explicitly clear search-owned caches.
3. Add byte-bounded event retention and finished-result ownership/release policy.
4. Coordinate TUI source/derived caches under one configurable byte budget.
5. Stream log replay and reduce selection/native scratch-buffer peaks.
6. Compare runtime profiles and allocator behavior after these changes.

Track live binary bytes, cache-owned estimates, process heaps, RSS/PSS, transient
high water, and navigation/streaming latency together. Use repeated open/search/
close/resize/drag cycles, 12+ conversations, multiple active parent/child runs,
slow subscribers, and completion bursts. Keep the existing durability, recovery,
selection, replay-gap and cancellation tests as invariants. Proposed budgets need
workload validation; this audit does not promise a particular total RSS ceiling.

## Reproduction

```sh
mix run scripts/rss_bench.exs core
mix run scripts/rss_bench.exs headers
cd packages/alto_tui
mix run ../../scripts/rss_bench.exs tui
mix run ../../scripts/rss_bench.exs legacy
mix run ../../scripts/rss_bench.exs search
mix run ../../scripts/rss_bench.exs hydration
ERL_FLAGS='+S 4:4 +SDcpu 2' mix run ../../scripts/rss_bench.exs tui
```

Source anchors: `lib/alto/session/children.ex` (`header/1`),
`lib/alto/session/child_index.ex`, `lib/alto/runner/execution/events.ex`,
`lib/alto/runner/execution.ex` (`result/4`), `lib/alto/runner/task_host.ex`
(`complete/2`), `lib/alto/front_end/registry.ex` (`finish_run/3`),
`packages/alto_tui/lib/alto/tui/{state,search,transcript,markdown,viewport,selection,saved_session}.ex`,
and the installed ex_ratatui dependency's `native/ex_ratatui/src/widgets/highlighter.rs`.
