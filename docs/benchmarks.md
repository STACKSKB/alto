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
