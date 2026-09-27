# Desloppification

Alto is at `0.0.1`. Preserve capabilities; internal APIs, formats, sequencing
and error details may change without migrations. Prefer Elixir, OTP and existing
libraries. Add no dependencies for this cleanup. Moving code or compressing
formatting does not count as simplification.

## Measurement

The fixed baseline is **40,655** physical production `.ex` lines under `lib/`
and `packages/alto_tui/lib/`. The 30% target is **at most 28,458**.

Current: **30,592 lines**, a **24.8% reduction**, with **2,134 lines remaining**.
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
  Nineteen tools share argument contracts for schema projection, defaults and
  validation; domain callbacks retain file freezing, Git confinement and authority.
- TUI state uses canonical catalog, task and run data. Rendering shares per-frame
  projections; backend event and approval flows reuse existing handlers. User
  and agent messages share input channels, receipts and validation.

Tool preparation relies on configuration's existing module-load boundary rather
than loading the module twice. The supervised preparation result is matched
directly, and its approval-detail size check sits in the success branch instead
of a single-use forwarding helper. The callback deadline, cancellation and
approval-data limits remain unchanged. TUI form values use a pattern-filtered
comprehension to build the field map without first constructing a filtered list.
Existing regressions cover transform ordering, frozen preparation, oversized
details, callback failures and form submission.
This pass removes **9 production lines**: **7 code lines** and **2 blanks**, with
**no documentation lines removed**. No dependencies or compatibility layers were added.
Historical pass notes remain in Git.

## Remaining work

The target is not met. Prioritize deleting duplicate workflows through functional
composition and canonical state. The “Analyze code duplication” findings have
been checked against callers; reject extractions that add adapters without
removing implementation. Recent CLI/menu/selection reviews found no substantial
remaining duplication; merely wrapping their distinct flows is not progress.
Provider response/state prototypes were discarded: after formatting, they
removed only five lines while adding a reconstruction step. A native Inspect
diagnostic renderer was also discarded: preserving redaction and media handling
left two recursive paths and only 23 lines saved before required fixes. Workspace lifecycle
and listener audits likewise found no large duplicate flow beyond the existing
shared storage, HTTP and connection mechanisms. A persistent native model-picker
prototype was discarded: action rows erased its formatted production savings;
keyboard shortcuts saved only 10 lines while changing interaction and adding state
handling. No picker behavior changes from that prototype remain.

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

The current core check passes **1,078 tests** with application modules preloaded.
The TUI suite passes **146 tests**, including delegated approvals and durable usage telemetry. The direct-call consolidation retains retry, cancellation,
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
