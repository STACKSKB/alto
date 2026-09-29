# Optimization implementation batch 1

Implemented against `4517152`, September 29, 2026. This follows the
[codebase audit](codebase-audit-2026-09-29.md). All four reviewed changes passed
validation and were kept. Sol implemented child release; Luna implemented file
slice detachment and the hash fast path. The coordinating agent reviewed and
tightened those changes, implemented the Codex change, and ran validation.

## Changes retained

| Audit item | Change | Verified result |
| --- | --- | --- |
| A5 | Release owned child handles after consuming outcomes, including cancellation and failed subscriptions; skip unsupported custom runners | Eight completed batch children leave **0** hosts alive, previously **8** |
| A6 | Detach small UTF-8 file content and final search snippets using the existing selective-copy helper | A 141-byte read retains **141 bytes**, previously **999,141**; a 140-byte search snippet retains **140 bytes**, previously **999,141** |
| A13, partial | Short-circuit the final persistence check when the digest is absent or resolved operations make it false | Settled-history tests and the full core suite pass; impossible-true cases no longer serialize/hash the transcript |
| A1, partial | Drop raw Codex reasoning when the first summary arrives and ignore later raw deltas | After 2 MB of hidden raw deltas, the 13-byte summary remains visible with **167 serialized bytes** of entry state; previously the entry was evicted |

The Codex test also checks 2.5 MB of hidden deltas and that the completed item
remains authoritative. Child lifecycle tests cover a suspended outcome with its
exact checkpoint, cooperative cancellation, failed subscription, and a custom
runner lacking `release/1`. Existing integration coverage exercises asynchronous
child checkpoint/resume. Public result-host retention behavior is unchanged;
release applies to results consumed internally by `Agents`.

## Validation

- Core: **1,158 tests, zero failures**, 63.9 seconds.
- TUI: **211 tests, zero failures**, 13.7 seconds.
- Both suites ran sequentially with
  `mix test --preload-modules --seed 337473 --max-cases 8`.
- All changed Elixir files passed `mix format --check-formatted`.
- `git diff --check` passed.
- Repeated the original offline synthetic probes after compiling changed code.
  [Raw results](measurements/optimization-batch-1-2026-09-29.json) preserve all
  samples, including unrelated probes; their timing variations are not attributed
  to these changes.

The measurements above are process counts, referenced binary sizes, and
serialized entry sizes—not measured OS RSS savings. No live provider request or
interactive terminal UX session was used. This batch adds small ownership and
guard logic plus regression tests; it does not claim a net SLOC reduction.

## Review decisions and remaining work

Rejected the initial whole-result recursive detachment in favor of copying only
the relevant content, and replaced a verbose hash predicate with a short-circuit
expression. Reworked tiny-slice tests that would have passed before the fix, and
corrected test fixtures to remain within the search file-size limit. No final
production candidate failed validation or required rollback.

A1 is not fully resolved: raw-only reasoning and long summaries still need a
bounded indexed accumulator that preserves ordering and displayed prefixes.
A13 still hashes when persistence is possible; a generation-based approach needs
broader persistence validation. Rendering/index compaction, bounded diff
computation, registry I/O, and scheduling changes remain deferred to separate
batches. They were not rejected as invalid; they were outside this bounded batch.
