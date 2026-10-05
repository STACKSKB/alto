# Offline benchmarks

These workloads measure execution, storage, and terminal rendering without paid
model requests. Compare results from the same checkout, machine, and load;
latency and RSS depend on the scheduler, filesystem, native allocator, and
terminal environment.

## Core

Run from the repository root:

```sh
mix run bench/tool_batches.exs
mix run scripts/harness_storage_bench.exs
mix run scripts/redundant_storage_bench.exs
mix run scripts/rss_bench.exs core
```

The [tool-batch benchmark](../bench/tool_batches.exs) compares eight synthetic
read calls in serial and an explicit parallel group of four. Every sample checks
that all calls ran and their results returned. The
[storage workload](../scripts/harness_storage_bench.exs) measures durable append,
transcript persistence, and resume reads with disposable data. The
[RSS workload](../scripts/rss_bench.exs) reports BEAM and Linux process memory.
The [redundancy workload](../scripts/redundant_storage_bench.exs) measures single-body
events, incremental child checkpoints and conversation references in runner
checkpoints with disposable data. To measure incremental conversation conversion
on temporary copies of saved sessions, run:

```sh
mix run scripts/conversation_storage_bench.exs SESSION_ID [SESSION_ID ...]
```

It verifies every retained revision and dispatch fence without changing the
original session files.

## Terminal UI

Run from `packages/alto_tui`, where ExRatatui and the TUI modules are available:

```sh
mix run ../../scripts/tui_workload_bench.exs
mix run ../../scripts/tui_selection_bench.exs
mix run ../../scripts/tui_incremental_bench.exs
mix run ../../scripts/beam_append_bench.exs
mix run ../../scripts/tui_scroll_bench.exs
mix run ../../scripts/tui_redundancy_bench.exs
mix run ../../scripts/tui_memory_cycles_bench.exs sample
mix run ../../scripts/rss_bench.exs tui
```

These use synthetic conversations to exercise scrolling, selection, incremental
stream updates, cache turnover, and repeated native rendering. RSS probes use
Linux `/proc`. Native drawing measurements exclude terminal-emulator latency.
The scroll workload reports cold and repeated index/window/frame timings; the
redundancy workload compares a visible-only viewport with the whole history's row
count. Serialized representation size is not an RSS measurement.

To measure navigation across your saved tasks:

```sh
mix run ../../scripts/tui_navigation_bench.exs SESSION_ID_A SESSION_ID_B
```

The [navigation workload](../scripts/tui_navigation_bench.exs) reads existing
history and may refresh disposable `.cache` projections. It does not change the
catalog or start model runs. The incremental workload also accepts optional
saved session IDs for read-only transcript measurements.

Scheduling and rendering measurements do not establish model quality, provider
latency, token usage, or cost. Record provider-reported usage and request settings
separately when comparing live model runs.

## Runtime audit fixes, 2026-10-05

The starting revision was `700fb3a09430f4f0de83e123ceb9ab89e2743a6c`.
The [measurement record](measurements/runtime-audit-fixes-2026-10-05.json)
contains the synthetic samples, environment and validation counts. All workloads
ran locally on Elixir 1.18.3 / OTP 27 with 16 online schedulers. No model requests
were made. The original audit evidence and saved user sessions were left intact.

The fixes preserve terminal reasons and classify reasoning-only output separately;
retain observed accounting across failures, retries and worker deadlines; separate
event and cumulative stream budgets; offer bounded ordered observer ownership;
and remove per-delta history list rebuilding. Live and saved TUI totals now include
failed-attempt usage without counting successful completions twice. Unknown usage
remains unknown in bounded per-attempt evidence. See
[stream diagnostics and limits](sse-adapter.md#stream-budgets-and-partial-responses)
and [observer delivery](extensions.md#composing-execution-policies) for the contracts.

| Synthetic operation | Before | After |
| --- | ---: | ---: |
| First publication, 400 messages / 760,400 transcript bytes | 1,415.933 ms | 102.807 ms |
| Unchanged transcript publication, mean of 10 | 48.115 ms | 40.473 ms |
| Cold index, 100 assistant entries | 413.319 ms | 37.448 ms |
| Changed-tail index, median of 5 | 0.583 ms | 0.298 ms |
| 20 scroll events and frames, median of 5 | 25.471 ms | 26.128 ms |

Storage now syncs each immutable object's contents, batches directory syncs, and
publishes the head only after those syncs succeed. The previous benchmark averaged
first publication together with unchanged writes, hiding the cold cost. The
current workload reports them separately. One appended-tail sample was 139.588 ms
versus 95.114 ms before; these samples establish no improvement for that path.
Cold indexing avoids duplicate shared-block measurements and defers native syntax
setup for exact, short ASCII metrics. Styled visible content still uses the native
renderer. Large code-block cold scrolling stayed near 99 ms, and warm frame
performance stayed similar; the cold index improvement does not imply every
rendering workload improved.

Streaming initialization is measured separately from steady updates. With 100,
1,000 and 2,000 history entries it took 0.049, 0.117 and 0.282 ms. The following
1,000 deltas took 3.915, 3.325 and 3.523 ms, respectively, with no repeated history
prefix append. The display tail remains capped at 64 KB and freezes when shortened.
Reading the full transcript still materializes its prefix at the rendering boundary.

The [BEAM append probe](../scripts/beam_append_bench.exs) checks the binary claim
independently. Owned 4-byte appends at 4,096, 8,192 and 16,384 deltas took median
154, 293 and 611 microseconds. The bounded TUI path took 15.214 and 33.868 ms at
4,096 and 8,192 deltas. These samples do not support a blanket claim that every
binary append copies the entire accumulated text. Exact backing size alone also
does not establish copying behavior. The fix targets the confirmed history-list
cost while retaining the bounded binary representation.

The seven final workloads completed: tool batches, storage publication, redundant
storage, core RSS, TUI incremental updates, scrolling and viewport redundancy.
The viewport retained 40 visible rows from 20,790 total rows; the checkpoint
workload verified exact restoration from a referenced packet. The production
contrib escript was rebuilt and copied to the ignored root `alto` executable;
`./alto --help` verified current configuration and attachment options.

Cached path dependencies can contain old production bytecode. To refresh this
checkout's CLI, run from `packages/alto_contrib`:

```sh
MIX_ENV=prod mix deps.compile alto --force
MIX_ENV=prod mix escript.build
cp alto ../../alto
```

The build here reused the checkout's existing dependency and build directories
with `MIX_DEPS_PATH` and `MIX_BUILD_PATH`. Every packaged core and contrib BEAM
module's code fingerprint was compared with the fresh production build before
checking CLI help; escript packaging strips debug chunks.

Final suites passed with 417 core, 814 contrib and 240 TUI tests. The original live
240-second timeout cannot be attributed from offline workloads; the new bounded
diagnostics provide evidence for a future live investigation.
