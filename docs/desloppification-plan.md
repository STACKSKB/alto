# Desloppification

Alto is at `0.0.1`. Internal APIs and formats may change without migrations.
Preserve useful capabilities, including configured extensions, but do not retain
an abstraction merely because a test exercises it. Prefer existing Elixir/OTP
and installed-library APIs over custom implementations. Measure complete flows;
moving code or compressing formatting is not a reduction.

## Measurement

The original baseline is 40,655 physical production `.ex` lines in `lib/` and
`packages/alto_tui/lib/`. The 30% target is at most 28,458 lines. Tests,
documentation, generated output, and dependencies are counted separately.

The latest pass starts at 33,064 lines and removes 317, leaving 32,747
(19.5% below the original baseline), with 4,289 still to remove.

Reproduce the production count with:

```sh
git ls-files -z 'lib/*.ex' 'packages/alto_tui/lib/*.ex' |
  xargs -0 -I{} sh -c 'test ! -f "$1" || wc -l "$1"' sh {} |
  awk '{sum += $1} END {print sum}'
```

## Findings from the fresh review

- The workspace picker had a remote/async completion protocol used only by
  tests. It now uses the existing synchronous local folder service directly.
- The context pane filtered out entry kinds that its formatter still handled.
  Those unreachable cases and the duplicated detail branch are removed.
- The diff renderer translated Myers tags into a second internal vocabulary,
  rebuilt line endings recursively, and allocated filtered lists just to count
  hunk lines. It now uses library tags, regex line splitting, and map/reduce.
- Folder completion now uses OTP's longest-common-prefix operation, with the
  existing UTF-8 boundary helper. The test-only completion wrapper is removed.
- Tool metadata callbacks no longer pass through a wrapper around `apply/3`.
- Conversation snapshots no longer expose an unused derived entry ID. The
  atomic transcript/dispatch fence and revision conflict checks remain.
- Queue replay and live mutations now share native commands. A complete atomic
  snapshot replaces the multi-record snapshot/checksum protocol. Queue IDs are
  integers, and all persisted values must be portable. Old formats are rejected.
- Operation logs no longer write unused version/timestamp command envelopes.
- Context construction and continuation IDs use their canonical APIs directly.
- Git tree parsing uses one split and the existing fallible reduction helper.
- The SSE dependency change predates the latest session commits and replaced
  two parser implementations. This pass adds no dependencies.

## Larger work still open

Local cleanups alone have not reached the target. Reassess whole representations
across queue/ledger replay, retained parent/child continuations, and TUI task
state. Prior clone scans and unsuccessful extractions do not establish that
these flows cannot be simplified. Keep durable append-before-dispatch behavior,
explicit unknown outcomes, and bounded retention when replacing them.

Selection keeps raw text capture because exporting cell maps made mouse-down
substantially slower. Boundary rows now use `String.graphemes/1` instead of a
custom tokenizer and binary-search index; renderer-derived glyph widths still
account for wide-cell continuations.

Remove tests that merely echo constructors or exercise unused scaffolding.
Retain tests that distinguish behavior across malformed input, concurrent writes,
interrupted execution, and actual user interactions. Run focused checks and the
affected full suites after each coherent change.

Validation: the complete core suite passes 1,010 tests and the TUI suite
passes 137. Selection viewport output matched the prior implementation across
nine Unicode cases; mouse-down remained about 1 ms at 200×60.
