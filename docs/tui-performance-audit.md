# TUI and harness performance audit — September 28, 2026

## Conversation navigation: measured and fixed

The previous rendering-only benchmark missed synchronous work inside the mouse
handler. On two real saved conversations (242 and 205 display entries), a cold
mouse release spent 756–856 ms loading history before rendering began. Rendering
and native drawing added another 50–119 ms. Their histories contain thousands of
wrapped rows. Before the earlier visible-tail rendering change, full transcript
layout alone took 1.8–3.6 seconds.

The session directory contained 3,489 JSONL logs, totaling approximately 33.5 MB.
Discovering one parent's children reopened up to 4,096 session headers. This ran
inside the UI process, along with transcript decoding, tool presentation, usage
replay, and reconstruction of child activity.

Implemented changes:

- The interactive app hydrates history in a monitored background process. It
  publishes accounting and transcript entries before discovering child activity.
  Selection and input remain responsive. Obsolete work is cancelled and late
  results cannot change the newly selected conversation. A message submitted
  during initial hydration is queued and retained even if the user navigates away.
- `Session.ChildIndex` shares a bounded header cache across loader processes.
  Discovery still checks filenames and file metadata, but unchanged logs are not
  reopened/decoded. Changed, replaced, incomplete, and deleted logs are handled.
  It retains at most four directories, with the existing 4,096-file scan bound.
  Parent lookup uses an adjacency map instead of repeatedly scanning all headers.
  The index is disposable and reconstructed from logs, never execution authority.
- Saved child replay groups records by run once, avoiding a complete log scan
  for every child in a shared session.
- Read-only conversation fetches use the atomically published head without
  spawning `flock` or waiting for a writer. Resume, dispatch, and persistence keep
  their locks and revision checks. A regression holds the writer lock while a
  viewer successfully reads the previously published head.
- The task cache now evicts the least recently used inactive task, instead of
  sorting opaque task IDs. Active tasks and queued input remain protected.
- Clicking the composer or context no longer requests full transcript layout
  for selection. Transcript dragging still uses absolute history coordinates.
- The earlier visible-tail renderer and bounded caches across conversations
  remain in place. Neither selecting a task nor its ordinary redraw lays out
  the entire hidden history.

## Validation and measurements

The checked-in benchmark runs mouse-down/up through `App.handle_event`, then
`App.render` and the native `CellSession.draw`. It reads saved sessions and does
not register projects, mutate the catalog, or start a model:

```sh
cd packages/alto_tui
mix run ../../scripts/tui_navigation_bench.exs sess-FIRST sess-SECOND
```

At 180 columns by 50 rows, one post-change run measured:

| Operation | Conversation A | Conversation B |
| --- | ---: | ---: |
| Cold selection frame, including native draw | 5.8 ms | 8.7 ms |
| Cold transcript frame, including native draw | 146.6 ms | 145.9 ms |
| Child details ready, measured from click | 380.3 ms | 252.3 ms |
| Cached switch, including native draw | 12.7 ms | 12.5 ms |

A separate visual check launched the actual native app callbacks in an isolated
Xvfb/xterm, injected XTest mouse clicks, and inspected screenshots. The selected
conversation, Markdown styling, bounded tool output, and pane layout were checked.
Times from injection to the selected conversation's render callback were
8.2/20.0 ms for initial feedback, 160.6/140.7 ms for cold transcript availability,
and 20.8/26.5 ms for cached switches. Mouse-down redraws of the *old* conversation
were excluded. These are small-sample software timings, not physical
input-to-photon measurements or latency percentiles. Screenshots contain private
conversation content and were retained only under `/tmp/alto-visual`.

Tests cover cancellation and late results, queued input while navigating away,
merging live child activity, LRU eviction, index invalidation, and reads during a
writer lock. The full core run passed 1,139 tests. The full TUI run passed 193;
two subsequent added history regressions also passed.

## Follow-up implementation — September 29, 2026

All six follow-up areas now have implementations:

1. **Indexed historical layout and search.** A bounded row-count/plain-text index
   uses native wrapping without exporting the full styled cell grid. Independent
   entry batches build on at most four BEAM workers. Only the visible block ranges
   materialize styled cells; search uses the plain index and paints visible hits.
   Drag selection materializes newly visited ranges while preserving absolute row
   coordinates. Indexes remain cached even when a document exceeds the styled-row
   cache budget. Tests compare wrapping, styles, empty entries, tables, code and
   Unicode against the full native renderer.
2. **Coalesced streaming and incremental tail accounting.** Model/reasoning chunks
   accumulate for at most 32 ms, 256 chunks or 8 KiB before ingestion into displayed
   entries. Non-stream events and user input flush them first. Ingestion is
   acknowledged immediately; existing synchronous producer backpressure remains.
   Adjacent chunks of the same run/kind are joined once. Tail updates retain the
   stable prefix byte/count accounting rather than bounding the entire transcript
   on each token. Entry and byte limits still apply.
3. **Recoverable incremental projections.** Private disposable `.cache` files
   retain usage and bounded child activity plus the complete JSONL offset. A
   SHA-256 check of the consumed prefix detects truncation and same-length rewrites;
   only complete appended records are decoded/reduced. Torn tails wait for a newline.
   Invalid caches rebuild from logs. Child header metadata also persists across
   process/application restarts. Discovery still lists/stats bounded directory
   entries, but does not reopen unchanged headers. Caches never authorize execution
   or clear dispatch fences, and failure to write one does not fail session loading.
4. **Reuse validated transcript encoding.** Locked persistence reuses canonical
   validated bytes for archiving the old head and publishing the new one, avoiding
   two redundant whole-transcript encodings. Atomic replacement, immutable revisions,
   revision conflicts and dispatch fences retain their previous semantics. The
   current small timing sample did not establish an end-to-end persistence gain.
5. **Short-lived durable session writers.** A supervised per-session writer reuses
   the raw file descriptor and OS advisory lock for bursts, fsyncing every record
   before replying. It releases ownership after 2 ms idle or 20 ms of work and
   retires after one second idle. There are at most 64 writers; excess sessions use
   the direct durable append path. Failed opens retire, writer death releases
   ownership, and loss of the lock port stops the writer. Ambiguous failed writes
   are not retried. Concurrent-write, process-death and failed-open recovery tests
   verify records remain complete and are not duplicated.
6. **Counted event queues.** Core execution and front-end reconnect retention use
   bounded queues, avoiding per-event list-length and tail-deletion scans. Ordering,
   replay-gap reporting and exact dropped-event counts are preserved, including
   zero capacity and changing bounds.

### Follow-up measurements

These are local, small-sample timings; filesystem, CPU load and terminal rendering
matter. The storage benchmark uses `/tmp`, so its fsync timings do not represent
persistent-disk latency on other machines.

| Probe | Before | After |
| --- | ---: | ---: |
| 1,000 streaming updates, 100 retained entries | 30 ms | 4.8 ms |
| 1,000 streaming updates, 1,000 retained entries | 325 ms | 14.4 ms |
| 1,000 streaming updates, 2,000 retained entries | 659 ms | 24.7 ms |
| Full styled history / cold plain index, conversation A | 1.8–3.6 s full-layout range | 317 ms index |
| Full styled history / cold plain index, conversation B | same full-layout range | 218 ms index |
| Materialize 40 historical rows after indexing, A / B | full document required | 1.2 / 3.4 ms |
| 2,000-record saved replay, cold / cached / one appended | — | 94 / 11 / 12 ms |
| 50 serial fsynced appends, average | 3.37 ms | 0.019–0.090 ms |
| Persist a 760,400-byte transcript, average of 10 | 15.7 ms | 15.8–31.9 ms |

A repeat Xvfb/xterm test showed selected-conversation feedback in 22/36 ms,
transcript availability in 385/300 ms, and cached switches in 40/47 ms. First
historical scrolling took 255 ms to build the cold index; subsequent scrolling
was 21 ms. Screenshots were inspected for historical Markdown, bounded tool
output and layout after scrolling/dragging. These measure native render callback
availability, not physical input-to-photon latency. Compared with the earlier
run, cold transcript conversion remains variable and is not claimed to have
improved; it runs off the input path and child discovery still runs after it.

Validation: the full core suite passed **1,144 tests**, the full TUI suite passed
**201 tests**, and two additional streaming retention regressions passed afterward.
The final writer lock-loss hardening also passed all 29 targeted storage tests.

Reproduce the synthetic probes and optional saved-history index measurement:

```sh
mix run scripts/harness_storage_bench.exs
cd packages/alto_tui
mix run ../../scripts/tui_incremental_bench.exs [sess-FIRST sess-SECOND]
mix run ../../scripts/tui_navigation_bench.exs sess-FIRST sess-SECOND
```

Navigation can refresh disposable `.cache` projections. It does not mutate the
catalog, saved transcripts or start model runs. The incremental benchmark uses
synthetic temporary logs; optional session IDs only read existing transcripts.

### Practical bounds

Cold historical scrolling still needs a row-count index before its first frame;
resizing invalidates width-dependent layouts. Cached projection validation still
reads/hashes the bounded log prefix even though it avoids decoding old records.
Child discovery still checks file metadata across the bounded directory scan.
Durable transcripts remain complete snapshots rather than a new checkpoint/delta
storage format. These bounds preserve recovery behavior and identify where future
profiling should focus if larger workloads exceed the measured results.
