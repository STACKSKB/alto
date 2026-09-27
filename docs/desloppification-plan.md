# Desloppification

Alto is at `0.0.1`. Preserve capabilities; internal APIs, formats, sequencing
and error details may change without migrations. Prefer Elixir, OTP and existing
libraries. Add no dependencies for this cleanup. Moving code or compressing
formatting does not count as simplification.

## Measurement

The fixed baseline is **40,655** physical production `.ex` lines under `lib/`
and `packages/alto_tui/lib/`. The 30% target is **at most 28,458**.

Current: **31,157 lines**, a **23.4% reduction**, with **2,699 lines remaining**.
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
  Seventeen tools share argument contracts for schema projection, defaults and
  validation; domain callbacks retain file freezing, Git confinement and authority.
- TUI state uses canonical catalog, task and run data. Rendering shares per-frame
  projections; backend event and approval flows reuse existing handlers. User
  and agent messages share input channels, receipts and validation.

Context in the TUI now has one full-screen presentation, selected by focus,
instead of separate persistent-sidebar, drawer and full-screen state machines.
Context content, approval decisions, scrolling, selection, clipboard access and
form overlays remain; Esc or Tab returns to the composer. The old sidebar width
and narrow-layout settings are removed, with no compatibility wrapper. Background
run completion leaves manually opened context alone, and open credential forms
retain input and masking when an approval arrives. This pass removes **148
production lines**: **117 code/typespec**, **26 blank**, and **5 source
documentation/comment** lines. All **145 TUI tests** pass, including real
rendering, mouse decisions, selection autoscroll, resize and queued-input flows.
Core code is unchanged; its last full run passed **1,075 tests**. No dependency
or migration was added.

Child admission now uses one schema for types, defaults and bounds, replacing a
second constraints pass. Native tasks retain arbitrary terms except nil/empty;
string fields require UTF-8, and rejected input never dispatches a provider.
Markdown tables use labeled records at every width, deleting grid estimation and
fallback selection while retaining every cell, extra column and escaped pipe.
This pass removes **61 production lines**: **44 code/typespec**, **13 blank**, and
**4 source documentation/comment** lines. All **1,075 core tests** and **145 TUI
tests** pass. No dependency, migration or compatibility wrapper was added.

Consumer handlers now return canonical ledger actions or a runner result directly.
One path commits the ledger command and settles the queue claim; redundant outcome
aliases and separate decision, retry and checkpoint wrappers are removed. Retry
write failures retain the claim, while terminal acknowledgement failures preserve
the recorded outcome. Checkpoint restoration derives immutable bindings through
the capture path, retaining separate authority, expiry, budget and session checks.
This pass removes **64 production lines**: **51 code/typespec**, **10 blank**, and
**3 source documentation/comment** lines. The handler contract is documented in
[delayed queues](delayed-queue.md); no migration or dependency was added. All
**1,075 core tests** and **145 TUI tests** pass, including retry write/release
failures and malformed checkpoint bindings.

Command schema projection and default validation now share one argument contract.
Command policies are functions, portable MFA callbacks or literal rejections;
Invocation, Prepared, Policy and the two policy implementation modules are deleted.
Prepared commands and Bubblewrap execution use plain frozen maps, retaining PATH
resolution before approval and the same executor/stdio boundary. Explicit narrowed
child profiles can persist MFA policies and resume an approved command. NUL and
aggregate-byte checks, binary argv, process cleanup and sandbox authority remain.
This pass removes **116 production lines**: **89 code/typespec**, **23 blank**, and
**4 source documentation/comment** lines. The old and new command validators agree
on **35 boundary and binary-argument cases**. All **1,075 core tests** and
**145 TUI tests** pass; no dependency or migration was added.

Loop configuration is a plain driver/options/policy map. The Spec and Runtime
modules are deleted; Loop owns middleware composition and the execution host
calls module initialization directly. Rule scripts compile once to indexed data,
share one event-correlation path and retain native results across checkpoints.
Configuration files return keyword lists consumed directly by CLI, TUI and
runner; the Config constructor, struct and projection are deleted. Malformed
rule scripts now fail at construction. Module callback and durable child-resume
capabilities remain; no migration or compatibility wrapper is introduced.
This pass removes **100 production lines**: **68 code/typespec**, **15 blank**,
and **17 source documentation/comment** lines. Constructor-only coverage is
removed; restored-rule correlation and result propagation are exercised instead.
All **1,074 core tests** and **145 TUI tests** pass. The three offline Oban
example tests pass; its database test remains excluded.

Approval policies are now decision literals or two-argument functions. Six
policy modules are deleted; the interactive, resident and delegated front ends
share ordinary functions and exact-ID decision waiting. Frozen requests,
supervision, cancellation, inherited routes and durable suspension remain.
Usage accounting has one canonical map across provider ingestion, execution,
events, child results, checkpoints and TUI state. Field projection and cumulative
arithmetic are shared, and provider usage is normalized once per completion.
The [extension guide](extensions.md) documents both contracts.
This pass removes **130 production lines**: **90 code/typespec**, **22 blank**,
and **18 source documentation/comment** lines. A differential check matched
**15,000 provider, accounting and Codex projections**. The full core suite passes
**1,074 tests**. No dependencies, migrations or compatibility adapters were added.

Webhook configuration now uses path-keyed endpoint maps and captured verifier,
identity and admission functions. The Inbox behavior and Queue adapter modules
are deleted. Trusted callback preflight and duplicate-path scaffolding disappear;
body bounds, signed bytes, identity limits, shallow run-start deduplication and
durable acknowledgement checks remain. Queue, Oban and repository-maintenance
examples compose their ordinary admission functions directly. This pass removes
**164 production lines**: **114 code/typespec**, **31 blank**, and **19 source
documentation/comment** lines. The core suite passes **1,074 tests**; obsolete
constructor tests are removed while HTTP failure, concurrency and restart tests
remain. Three offline Oban tests pass; its database test is excluded. The example
lockfile now includes the existing SSE dependency already declared by Alto; no new
dependency was added.

Loop transitions, effects and scheduler frames now use tagged tuples across the
runtime, middleware, checkpoints and manual scheduler. Effect and Transition
constructor modules and the embedded Frame struct are deleted, with no replacement
constructors. Terminal tails, hook ordering, batch barriers and durable frame
validation remain at their execution boundaries. The [loop contract](loop-contract.md)
documents the tuples and preserves the removed modules' semantic guidance.
This pass removes **98 production lines**: **49 code/typespec**, **15 blank**,
and **34 source documentation/comment** lines. Fixtures and benchmarks now use the
same values as production; no compatibility layer or migration was added. All
1,077 core tests and 145 TUI tests pass.

The CLI now consumes the keyword list returned by `Config.load` for execution
settings instead of a parallel flag-to-provider/tool/prompt/sandbox compiler.
Execution override flags are removed;
all their capabilities remain available in trusted configuration. Setup, default
OpenRouter onboarding, tasks/stdin, sessions, listener controls and serving remain.
Configured workspace, persistence and approval choices are honored; served runs
still default to socket approval. This pass removes **227 production lines**:
**171 code/typespec**, **34 blank**, and **22 documentation/comment/help** lines.
Obsolete flag-precedence tests are replaced by actual configured writes and served
approval round trips, including an explicit unattended policy. All 1,077 core
tests pass.

Tool registration now builds one map containing runtime metadata and provider
definitions. Model exposure projects that map in name order and intersects
inherited visibility, removing the parallel definition accumulator and selector
adapters. Trusted providers, approvals, runners, reducers, transports and workspace
backends execute their contracts directly without callback-list introspection or
custom malformed-configuration wrappers. Tool permission/concurrency enums and
unknown/duplicate names remain checked; authentication failures still deny access.
Workspace backend loading remains explicit for optional cleanup callbacks. This
pass removes **68 production lines**: **57 code/typespec**, **11 blank**, and no
net documentation/comment lines. Constructor introspection echoes were pruned;
cold backend cleanup and deterministic inherited schema projection are exercised.

Context and child admission now use canonical maps containing functions, deleting
Context.Policy and Subagents.Policy. The built-in constructors retain option
validation; custom callbacks capture configuration directly. Child limits can
still come from a per-run factory under the existing timeout and cancellation
boundary. The resolved map supplies admission, tool schemas and runtime ceilings.
Checkpoint fingerprints bind both factory and resolved policy, including callback
code and durable identities for captured workspace resources. This pass removes
**125 production lines**: **86 code/typespec**, **26 blank**, and **13
documentation/comment** lines. Constructor validation echoes were removed while
factory cancellation, deadlines, child authority and checkpoint binding coverage
remain.

TUI forms and menus now share one item list, selection, scrolling window,
keyboard/paste handling, renderer and mouse hit-testing path. Fields use native
inputs and actions use closures; the separate TextForm module is deleted. The
selected field is edited above the list, with locked IDs, masked credentials,
folder completion/creation and worktree actions retained. Empty menu space cannot
activate actions. This pass removes **59 production lines**: **40 code/typespec**,
**18 blank**, and **1 documentation/comment** line.

Prompts, retry policies and tool presenters now use function callbacks. Configured
options live in closures; the Prompt.Builder, Retry and ToolPresentation dispatch
modules are deleted. Retry defects stop retries with a fixed, redacted warning;
presenters retain timeout, cancellation and fallback behavior. Prompt tool metadata
uses the same configured defaults as execution. This pass removes **103 production
lines**: **76 code/typespec**, **21 blank**, and **6 documentation/comment** lines.
All 1,083 core tests pass, including actual failing-policy execution and configured
tool-name projection. The shipped configuration loads all 15 tools.

Middleware now composes three-argument functions directly; lifecycle hooks use
closures in the same chain. The Hook, Middleware and Middleware.After dispatch
adapters are deleted. Ordinary and compaction model requests now share dispatch,
retries, model-count and usage accounting. Concurrent reducer callbacks serialize
through that shared run state, with the provider still unable to dispatch tools.
Successful provider usage is retained even if transcript insertion fails.
This pass removes **101 production lines**: **76 code/typespec**, **23 blank**,
and **2 documentation/comment** lines. Middleware ordering and the concurrent
reducer step cap have focused regression coverage.

Tool configuration now has one registration/preparation boundary. Six file tools
consume configured default maps instead of repeatedly validating host options;
wrapped tools freeze the same inner configuration. Command policy/executor
specifications use tuples, and malformed trusted callbacks fail under the existing
supervision boundary. Setup composes prompts directly and uses native struct/schema
contracts instead of separate malformed-option error wrappers. External arguments,
resource ceilings, frozen approvals and durable data still retain their checks.
This pass removes **109 production lines**: **89 code/typespec**, **17 blank**,
and **3 documentation/comment** lines. No dependencies or migrations were added.

Trusted host configuration now uses one provider profile representation:
`%Alto.Harness.ProviderProfile{}` with tuple provider specifications and atom-keyed
catalog maps. The map/keyword profile coercion and string/string-key model aliases
are removed, including TUI fallback projections. Defaults, duplicate-ID protection,
cold discovery, catalog metadata and credential resolution remain. The launch
profile and fixtures use this contract; no migration or compatibility layer was
added. This removes **60 physical production lines**: 46 code/typespec and 14 blank
lines. Obsolete shape-normalization assertions were pruned; all 1,092 core and
143 TUI tests pass.

Provider saves and startup now share effective-profile construction, preserving
configured provider options, catalog metadata and credential aliases without a
separate TUI merge path. Referenced credential aliases no longer appear as extra
profiles. The settings bar uses one ordered control list and consistent shortcut
labels at every width, with compact values on narrow terminals. These changes
remove **48 physical production lines**: 40 code/typespec and eight blank lines;
no source documentation was removed. Both full suites pass (1,093 core, 143 TUI).

JSON-RPC now owns the entire pending-request lifecycle for MCP and Codex:
initialization settlement, response routing, timeout cancellation, caller-monitor
cleanup and failure replies. Protocol modules retain handshake validation,
notifications, tool caching and result interpretation. One canonical pending record
replaces protocol-specific reply tuples, and shared notifications use one encoder.
Transport errors use `json_rpc` tags; dispatched MCP calls remain uncertain on
transport loss, while received errors settle only their request. This removes
**105 physical production lines**: 82 code/typespec lines, 22 blank lines and one
net documentation/comment line. Integration coverage checks cancellation on the
wire, client reuse after timeout, and independent failed/successful requests.

Folder entry now uses the existing text form, and folder suggestions use the
existing searchable menu. The standalone folder picker and its separate rendering,
geometry, input and mouse-selection paths are removed. Ctrl+O opens suggestions;
selection returns to the typed form, Enter opens it, Tab completes paths, and
Ctrl+N creates folders. Shared menu hit testing accounts for scrolling and excludes
border cells. Configuration no longer maintains a duplicate option registry:
trusted keyword options are validated by their consumers, with TUI constraints
owned by TUI State. Operator inspection joins projected queue/ledger records
instead of rebuilding flattened aliases; payloads and checkpoint contents remain
private. These contract and workflow changes remove **293 physical production
lines**: 232 code/typespec lines, 26 blank lines and 35 documentation/comment lines.
Constructor-echo tests were removed; integration coverage exercises configured
execution, inspection privacy, folder creation/completion and scrolled mouse input.

Completed runs now carry `status` and `reason` directly on `Runner.Result`.
Sessions, child summaries, CLI/TUI completion and subscriber notifications consume
that record instead of unpacking and rebuilding success/error tuples. Bounded
child projections retain accounting and effect `verdict`; subscriber projections
exclude transcripts and events. Session audit records use `status`, and listings
use `last_status`. These API and record changes have no compatibility adapters.
The TUI also removes its obsolete run-monitor completion/cleanup path; completion
subscriptions already handle worker failure. This pass removes **70 net production
lines**: 69 implementation lines and one source documentation/comment line.
A workspace-retention prototype was discarded because it grew after formatting.
The canonical-result change passes all 1,091 core tests and 144 TUI tests; coverage
includes malformed restored child summaries, nested tuple errors with successful
siblings, cancellation, suspension and real TUI worker-crash recovery.

Budget accounts and child continuations now share one generation-bound retained
record, storage envelope, validated snapshot and lifecycle. The change removes
**56 net production lines**: 58 implementation lines removed, with two source
documentation lines added. Domain callbacks retain counter limits, child grants,
approvals and join eligibility. Ledger mutations fence both generation and revision,
preventing stale handles from modifying a reused key with a colliding revision.
The storage format and handle types change without migrations. Generated-schema
metadata assertions were pruned while runtime validation coverage remains.

Clipboard reads and writes now reuse supervised invocation, removing both local
task-wait/shutdown paths and **28 implementation lines**. Private stdin files,
desktop helper selection, timeout handling and OSC 52 fallback are retained;
all 144 TUI tests pass. No source documentation was removed in this pass.

The preceding cleanup removed **67 net production lines** across twelve modules:
69 implementation lines removed, with two net documentation/typespec lines added.
Supervised calls return callback values directly and share failure/cancellation
tags, removing repeated unwrapping across execution, consumers and front ends.
Cancellation still preserves completed siblings and bypasses false tool-result
commitments; mutation uncertainty remains classified at dispatch boundaries.

The canonical-record cleanup removed 65 net production lines: 54 implementation lines
and 11 lines from the now string-keyed snapshot typespec. Conversation storage,
revision reads, forks and resume now share the same JSON-shaped record instead
of carrying paired storage/public representations. Provider profiles normalize
structs, maps and keywords through one path. The conversation format is version
4; old formats are rejected without migration.
The tool-contract pass removed 106 production lines. Input ownership
and ledger transition composition removed 26 and 77 lines in preceding passes.
The separately requested worktree feature added 426 production lines, included
in the current total without resetting the baseline.
No dependency or migration was introduced. Earlier cleanup introduced one SSE
library to replace two parsers; subsequent passes have added no dependencies.

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

The current core check passes **1,075 tests** with application modules preloaded.
The TUI suite passes **145 tests**, including delegated approvals and durable usage telemetry. The direct-call consolidation retains retry, cancellation,
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
