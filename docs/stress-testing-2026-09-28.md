# Space Bunny performance workload, September 28

Alto ran Space Bunny Alpha against the HotLimit sketching application. The
performance conversation is `sess-qxupm7zwmxbzlua`. An initial 72-request run
stopped at its configured budget and persisted successfully; a resumed run
completed in 36 logical model cycles. Five corrective parent steers were consumed
in the first run and three in the continuation. This phase did not compact.

## Application evidence

The worker implemented per-layer committed-stroke raster caches with full live
stroke replay, retaining vector data. Independent fresh compilation and execution
passed 1,241 cache checks against an uncached pixel oracle. Worker tool records
also show successful full application, UI, no-cache, save/load, allocation-fault
and AddressSanitizer/UndefinedBehaviorSanitizer checks. Fault tests passed 3,018
checks; the cache-disabled suite passed 927.

At 1024x768, 300 timed append-plus-composite samples, the same benchmark built
with and without the cache reported the following median / p95 milliseconds:

| Scenario | Uncached | Cached |
| --- | --- | --- |
| 32 historical strokes, one layer | 7.345 / 8.995 | 3.310 / 4.130 |
| 128 historical strokes, one layer | 20.107 / 27.296 | 3.953 / 4.512 |
| 128 historical strokes, middle of three layers | 25.457 / 31.440 | 5.384 / 6.645 |
| 128 historical strokes, erasing | 21.144 / 23.528 | 4.830 / 6.174 |

Cold first-sample cost remains about 20 ms at 128 strokes. These are CPU timings,
not input-to-photon measurements. Cold trials use 20 repetitions and restore the
same history between trials. A later cached rerun yielded similar results.

Review rejected early benchmarks that skipped warm-up, changed history between
cold trials, or read unavailable cache statistics. Review and pixel tests also
caught stale-tail blending, missing cache invalidation, an accidentally removed
public compositor function, and a cold-prefix regression. Final timings above
come after those corrections, not from the rejected measurements.

## Alto findings

- `model_requests` counts logical cycles, not provider transport calls. At the
  72-request cap the result reported 73 cycles, with only 72 completed provider
  calls. Retries can produce the opposite relationship. Documentation and a
  focused budget-denial regression now make that distinction explicit (66f84cf).
- A resumed worker tried its previous parent's complete but stale agent ID. The
  old unknown-recipient diagnostic incorrectly emphasized a missing prefix. The
  tool now directs stale recipients to rediscover the current tree, preserving
  exact prefix suggestions when applicable (d71e4cd). Twelve messaging tests pass.
- The model repeatedly requested a 300000 ms command timeout despite the exposed
  120000 ms schema/prompt limit, then recovered. This remains tool-UX evidence;
  the schema already includes minimum, maximum and default.
- The worker claimed edit failures omitted an index. Recorded errors include
  `edit_index` and a reread hint, so that report is not supported by the trace.

A subsequent bounded continuation lowers the transcript limit to exercise live
handoff compaction while investigating commit/cold-transition latency. Its
outcome is not included in the completed evidence above.

## Live compaction and malformed arguments

The next continuation compacted 804,306 bytes of history into a 14,300-byte
handoff while retaining four recent messages. Parent steers `COLD_ORACLE` and
`COMMIT_ROLLBACK` were consumed afterward. The worker rediscovered the current
agent tree before proceeding.

At its ninth model cycle, a completion used all 4,096 output tokens and supplied
an incomplete `read_file` argument object. `JSON.decode/1` returned
`{:error, {:unexpected_end, 13}}`; the runner incorrectly called
`Exception.message/1` on that tuple and crashed. This is a harness bug: malformed
model arguments must produce a recoverable tool error, not terminate execution.
The same misuse exists in the JSON-RPC decoding path. Both paths now return bounded static diagnostics. Forty-eight focused tests
passed, including actual-runner malformed-argument recovery in serial and batch
calls and malformed JSON-RPC startup input. Live continuation follows.

The last settled conversation survived at revision 119 with both steering
constraints intact. The crash result itself reported no session or final
persistence, so recovery uses the settled snapshot rather than that result.

The malformed-JSON fix subsequently passed the complete core suite: **1,130
tests, zero failures**. A new live continuation resumed normally from the
settled snapshot and consumed additional transaction-safety steers. This proves
resumption; it does not yet prove a second malformed live completion recovered.

The commit-latency workload also exposed a HotLimit heap overflow when starting
a stroke while another was live. The API promises to abort the older stroke,
but it checked buffer capacity before that abort replaced the arrays. An
independent ASan/UBSan probe reproduced the overflow with eight committed
strokes. After moving abort before pointer/capacity lookup, the same probe
passed at 8, 16 and 32 strokes, including undo and leak checking. The worker's
expanded cache suite passed 9,665 checks; the cache-disabled suite passed 9,338.
Final commit timing validation remains in progress.

## Final continuation and completion audit

The final Space Bunny continuation completed successfully in 25 logical model
cycles and persisted the same conversation. It compacted 452,519 bytes into an
18,314-byte handoff containing `COLD_ORACLE`, `COMMIT_ROLLBACK`, and
`TRANSACTION_SCOPE`. Another reduction produced no progress (40,282 to 40,284
bytes); Alto rejected it and continued executing tools. Two additional parent
steers were consumed during the final continuation. This provides live evidence
of constraints surviving successive handoffs across resumed runs, alongside the
scripted repeated-compaction regression.

After correcting benchmark failure handling and reporting total replay counts,
separate cached and uncached binaries completed at 1024x768 with **60 samples**
per steady/commit scenario (20 for cold first samples):

| 128 historical strokes | Uncached median / p95 | Cached median / p95 |
| --- | --- | --- |
| Append + composite | 19.006 / 22.956 ms | 3.315 / 4.044 ms |
| Commit + composite | 18.412 / 22.050 ms | 3.513 / 5.184 ms |

The normal warmed commit path is about 5.2 times faster. Truly cold first samples
still cost roughly 20 ms. Commit counters show one full initial replay and 59
single-stroke tail replays over 60 probes; this is not a claim that every commit
avoids the fallback. These measurements exclude SDL upload and display latency.

An independent final cache build passed 9,665 checks. The final worker reran
cached and cache-disabled suites successfully (9,665 and 9,338 checks). Earlier
full gates and sanitizer checks cover the unchanged application source; final
edits concerned benchmark validation/reporting only. The independent stroke
restart sanitizer probe also passed after the API fix.

The worker's final narrative incorrectly described the eraser's `full 128 / tail
60` total as full replay on every sample; the recorded totals mean one historical
rebuild plus 60 tail replays. It also classified exceeding an explicit timeout
and deleting a log with `make clean` as tool defects. Those incidents were not
harness failures, though they are useful evidence for future instruction and
error-message improvements. The malformed-JSON crash and stale-recipient hint
were actual Alto defects and were fixed during this workload.

This performance/stress-testing goal is complete: real application edits and
measured gains, independent correctness checks, fixed Alto defects with focused
and full regression coverage, durable failed/successful session resumption, and
live steering/compaction evidence. Physical tablet feel and display latency were
not acceptance gates for this Alto-focused workload and remain unmeasured. All
workload workers have stopped. HotLimit source is retained in its existing
checkout; no HotLimit commit or Git identity was invented.
