# Desloppification

Alto is at `0.0.1`: internal APIs and formats may change without migrations.
Preserve useful capabilities and extension contracts. Prefer existing Elixir,
OTP, and installed-library APIs; add no dependencies for this cleanup. Moving
code or compressing formatting does not count as simplification.

## Measurement

The original baseline is 40,655 physical production `.ex` lines in `lib/` and
`packages/alto_tui/lib/`. The 30% target is at most 28,458 lines. Tests,
documentation, generated output, and dependencies are counted separately.

The earlier pass reached 32,747 lines; model-selected subagents then added 593,
bringing the starting point for this follow-up to 33,340. The current worktree
removes 879 production lines, leaving **32,461 (20.2% below the original)**.
**4,003 lines remain** to reach the target. The reduction includes 15 lines of
duplicate Registry documentation; examples separately lose 39 implementation lines.

Reproduce the production count with:

```sh
git ls-files -z 'lib/*.ex' 'packages/alto_tui/lib/*.ex' |
  xargs -0 -I{} sh -c 'test ! -f "$1" || wc -l "$1"' sh {} |
  awk '{sum += $1} END {print sum}'
```

## Changes in the worktree

- Queue records have one map representation across storage, replay, and reads.
  Atomic snapshots replace the multi-record snapshot/checksum protocol; the
  snapshot format is version 8, with no migration. Ledger checkpoint operations
  share validation and no longer persist unused command envelopes.
  Budget packets omit immutable headers already stored in recovery metadata;
  the account format is version 2, with no migration.
  Stores share directory and ID validation; queue schedules accept one explicit
  non-negative delay or timestamp, with no options meaning immediate eligibility.
- Tools have one execution callback, `run/3`. Optional `prepare/3` returns the
  exact value passed through approval to execution. The second callback,
  preparation-mode state, and raw-argument wrappers are removed. Model discovery
  uses the same supervised batch, dispatch fence, and result bound as other tools.
- Context windows and bounded subagent policies use the existing `{module, state}`
  contract. Tokenizer adapters return a unary function. Redundant config structs,
  defaults, direct resolution APIs, and their helper-only tests are removed.
- Registry approvals use globally unique handles in one map; subscriber scope is
  one run ID or nil. Native TUI approvals inherit the owning UI run ID, avoiding
  retained approval sets and reverse lookups while preserving child identities.
- TUI rows and transcript text are computed once per frame. Rail actions carry the
  selected row directly. Forms, cancellation, completion, and queued-input paths
  share their existing state updates. Discovered model catalogs override profiles,
  including when discovery returns an empty catalog. Codex context limits live in
  per-task usage, removing the global value that leaked across task selection.
- Codex UI and delegated agents share bounded model pagination. Provider discovery
  and streaming share Req response handling. Validated Anthropic tool-input maps
  bypass JSON round trips. Provider observers use the existing notification helper.
- Session reads return canonical conversation snapshots. Execution setup owns run
  IDs; child summaries project result fields and share persistence-error handling.
  Redaction, protocol encoding, and header parsing each have one implementation.
- File tools and examples reuse bounded reads and option validation. Project
  instructions use `BoundedFile.range/3`; read/sync cleanup uses `File.open/3`.
  Workspace creation reuses source/root checks. Atomic writes retain close-error
  reporting and post-rename uncertainty with simpler control flow. Fresh and
  resumed workspace runs share completion handling; an unused resume wrapper is gone.
- Structured handoffs retain their four fields in one immutable JSON artifact,
  using shared atomic-write and lock helpers. Consumers use `artifact_path`;
  the multi-file directory publisher and legacy file map are removed.
- Unix sockets use bounded OTP line framing instead of a second line buffer and
  splitter. Webhook listeners retain only delivery IDs; routing owns validated
  endpoint maps without a second internal struct or duplicate endpoint state.
  MCP and Codex ports also use native framing, with per-message payload limits;
  startup success and failure share waiter cleanup.

The “Analyze code duplication” findings were checked against actual callers.
Extractions that added adapters without removing behavior were rejected.
No dependencies were added. The earlier SSE dependency replaced two parsers.

## Harness fixes

Tool JSON fallback normalizes unsupported terms while preserving the result
shape, so a tuple error cannot hide successful sibling output, run IDs, or usage.
Native values and custom JSON encoders keep their existing fast path.

The spawn schema reflects the resolved child limit. Regression tests cover
schema limits 1, 4, and 12; five children run under limit 5 and are rejected
before dispatch under limit 4.

## Remaining work and constraints

The 30% target is not met. Continue reviewing whole representations and repeated
flows, particularly retained continuations, queue/ledger replay, and TUI state.
Keep append-before-dispatch durability, single-use grants, explicit unknown
outcomes, bounded retention, and frozen approval values.

Distinct trust boundaries and failure modes are not interchangeable merely
because their code looks alike. In particular, retain exact session payloads
alongside their portable wire projection, and preserve different handling for
known rejection versus uncertain mutation. Terminal selection keeps raw text
capture because exporting cell maps materially slowed mouse-down handling.

Remove tests that only echo constructors or unused scaffolding. Retain tests
that distinguish malformed input, concurrent writes, interrupted execution,
recovery, and actual user interactions.

## Verification

The latest core run completed 1,042 tests with one outdated exact usage-map
assertion; that assertion is corrected and its regression passes. All **141 TUI
tests pass**. Rerun the full core suite after integrating agent messaging.
Run full suites sequentially with `--max-cases 8`; concurrent VMs caused timing
failures. Tests allow fixture startup time and establish prepared work or an
active turn before checking ordering and timeout interruption. Formatting and
diff checks pass.

Focused coverage includes mixed-error batches, child limits and authority,
continuation recovery, storage failures, frozen tool preparation, workspace path
checks, UTF-8 bounds, redaction, and observer exceptions/throws/exits. Terminal
selection benchmarks remain about 1 ms at 200×60.
