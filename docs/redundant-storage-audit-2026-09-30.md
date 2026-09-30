# Redundant storage audit — September 30, 2026

## Fixed: conversation snapshots

Version 4 archived the entire accumulated transcript at every boundary. The two
affected sessions contained 165 and 161 snapshots, consuming 79,044,719 and
126,949,785 bytes. This multiplied unchanged messages by the number of model
steps, even when there was only one new user turn.

Version 5 stores message payloads by content hash and shares immutable reference
chunks of at most 64 message hashes. Each revision is a small manifest. Unchanged
saves do not create revisions; dispatch-fence resolution still does. Keeping all
turns is the default. `conversation_retained_turns: N` retains every boundary
within the latest N user turns while preserving the entire current context.
Collection removes only objects unreachable from every remaining revision.

Implementation: [Conversation](../lib/alto/session/conversation.ex),
[Store](../lib/alto/session/conversation/store.ex),
[configuration and migration](conversations.md).

Measured conversion on temporary copies, with every revision's message digest
and the current dispatch fence verified afterward:

| Session | Revisions | Before | After | Reduction | Conversion |
| --- | ---: | ---: | ---: | ---: | ---: |
| `sess-2ofphnshf6tpkxa` | 165 | 79,044,719 B | 1,423,362 B | 98.20% | 9.66 s |
| `sess-itpsspcqj2pcdvq` | 161 | 126,949,785 B | 2,009,852 B | 98.42% | 10.95 s |

Original sessions were read only. These are file-content lengths on this machine,
not allocated filesystem blocks or RSS. Conversion performs a one-time full
history scan. Subsequent writes store changed payloads and bounded reference
chunks. Hashing/materializing the live context and storage metadata scans still
take time proportional to their inputs; this is not a constant-time write claim.

## Fixed: all four flagged copies

### P1: exact event terms plus portable event bodies

Previously `Session.event_record/2` wrote both a base64 ETF `data` term and its
JSON `wire_data` projection. Original-session measurements remain recorded below
as the audit baseline, excluding the enclosing keys and other record metadata:

| Session | Events | Exact `data` | `wire_data` | Complete JSONL |
| --- | ---: | ---: | ---: | ---: |
| `sess-2ofphnshf6tpkxa` | 516 | 985,100 B | 745,988 B | 1,808,784 B |
| `sess-itpsspcqj2pcdvq` | 487 | 1,805,720 B | 1,376,714 B | 3,259,431 B |

New events write a single versioned typed JSON tree through
[EventCodec](../lib/alto/persistence/event_codec.ex). Text occurs once; type tags
retain atoms, tuples, structs, binary values and exact map keys. Exact restoration
uses existing atoms only. Portable projection works even when a fresh VM cannot
resolve those atoms. The codec owns size/depth bounds and uses the existing ETF
codec for unusual runtime values; it does not call back into Session. Complex map
keys share the protocol's key encoder. A bounded display projection is retained
only for opaque runtime values and complex keys, not ordinary text bodies.

[Session.event_data/1](../lib/alto/session.ex) handles compatibility with old
exact-only and dual-body records. Recovery, socket replay, saved-session usage
and child activity readers use it. Old logs remain readable and are not rewritten.
For a synthetic 32 KiB text event, the complete record fell from **76,688 B to
32,987 B (57.0%)**, with exact round-trip and fresh-VM replay verified.

### P1: child updates rewrite all retained sibling checkpoints

[OperationLog](../lib/alto/operation_log.ex) now writes a
[map/tuple delta](../lib/alto/persistence/delta.ex) when it is smaller than the full
checkpoint update. Unchanged sibling checkpoint bodies and tuple fields are
reused. Replay verifies the exact base hash and applies the ordinary command's
generation, revision, phase and field checks. Full commands remain readable and
are used when a delta would exceed its replay bounds or increase record size.

Eight distinct 32 KiB child checkpoints previously produced **36 saved body
occurrences** across 16 updates and a **1,590,683 B** log. The same probe now
produces **8 occurrences** and **357,607 B (77.5% less)** under default ledger
limits. Exact aggregates survive restart, tuple decision/grant transitions keep
their saved bodies, torn trailing writes repair, and corrupt bases fail closed.

The aggregate checkpoint cap is independently configurable through
`max_checkpoint_bytes` (default 8,000,000 B). The default 64,000 B recovery-metadata
cap no longer prevents the second 32 KiB child from suspending. Explicit legacy
`max_recovery_bytes` settings continue to bound checkpoints unless the new option
is also set. Record (128,000 B) and log (64,000,000 B) defaults still apply.
Operation logs are not automatically compacted; legitimate changes still consume
space and callers can configure bounds appropriate to their workloads.

### P1: exact runner checkpoints repeat an already durable transcript

[Checkpoint](../lib/alto/runner/checkpoint.ex) now references the conversation's
verified session, revision, root hash and message count when the current saved
head exactly matches the run's transcript. Restore verifies the reference,
materializes the exact messages, and checks the ordinary transcript and authority
limits before executing anything. Unsaved/unpersisted history uses the existing
inline representation; old inline packets remain readable.

A **2,100,028 B** transcript now captures into a **2,345 B** complete packet and
restores exactly. The old inline decoded state would be **2,101,480 B**, exceeding
the 1 MB state cap. The cap still protects loop/prepared state and inline fallback.
The transcript reference removes this independent cap on already saved context.

The audit originally proposed separate pins. Code inspection showed that the
existing restore contract already rejects checkpoints after the current
conversation revision changes. A valid reference therefore remains protected by
the current head, which retention never prunes. No extra pin lifetime or abandoned
checkpoint cleanup mechanism is needed. Forged references and changed/pruned
revisions fail closed, including with finite turn retention.

### P2: viewport builds thousands of blank off-screen rows

[Transcript.viewport/5](../packages/alto_tui/lib/alto/tui/transcript.ex) now returns
[Window](../packages/alto_tui/lib/alto/tui/window.ex): visible styled lines plus
absolute offset and total row count. Native rendering receives only those lines;
scroll limits, search highlighting and selection preserve absolute coordinates.
Drag selection materializes new windows and retains visited selected rows rather
than rebuilding a padded full transcript.

The synthetic 200-entry, width-4 probe still has **20,790 total rows**, but its
40-row viewport now serializes to **13,559 B**, down from **3,520,400 B (99.6%)**.
These are representation sizes, not RSS. Regression tests verify full native
cell/style parity, search at nonzero offsets, and exact copying across autoscroll.
The earlier code-rectangle highlighting and transcript-index/cache fixes remain
in place.

## Upgrade behavior

New readers support old event records, full ledger commands and inline runner
checkpoints. New writes use the updated formats; restart Alto with the updated
code before resuming work, and do not run an older binary against newly written
state. Existing event/ledger logs are not compacted in place by these fixes.
Original sessions were not changed. Conversation conversion is available through
`mix alto.session.compact` as documented in [conversations](conversations.md).

## Copies checked that should remain

- Queue persistence already appends mutations and optionally replaces its log
  with one compact snapshot when full. Retained-cell `update/2` suppresses
  identical packets. These are not repeated full-history backups on each write.
- Context observation persistence already stores counts and digests rather than
  a second transcript. Runtime observation lists and cache keys can share BEAM
  binaries; adding their serialized weights is not proof of duplicate RSS.
- TUI cache accounting explicitly overcounts shared terms for a conservative
  budget. Codex reasoning now drops raw text once a summary exists and replaces
  streaming parts on item completion; the previous hidden-raw retention problem
  is not flagged as still present.
- Private forks own their selected message objects independently. Cross-session
  deduplication would require shared lifetime/pinning rules; independence currently
  lets a branch survive source pruning. Workspace copies likewise provide actual
  execution isolation, rather than historical transcript redundancy.
- Detached small display strings and frozen file-edit inputs prevent large backing
  buffers from staying alive and preserve stale-file/approval checks. Removing
  these copies would restore known memory or correctness problems.

## Reproduction and validation

```sh
mix run scripts/conversation_storage_bench.exs SESSION_ID [SESSION_ID ...]
mix run scripts/redundant_storage_bench.exs
cd packages/alto_tui
mix run ../../scripts/tui_redundancy_bench.exs
```

Core suite: **1,190 tests passed** with concurrency limited to eight. TUI suite:
**225 tests passed**. Focused coverage includes safe/fresh-VM event replay,
legacy records and packets, exact large-transcript restore, finite retention,
child aggregate restart and decision/grant transitions, corrupt delta rejection,
torn-write repair, native rendering parity, scrolled search and drag selection.
The first final core run exposed a pre-existing session-writer registry cleanup
race after process death. If both writer lookups return a dead process, a call
that was never delivered now falls back to the existing locked/fsynced append.
The same 1,190-test suite and failing seed then passed. Formatting and whitespace
checks passed. No provider calls or original-session
mutations were made by the measurement probes.
