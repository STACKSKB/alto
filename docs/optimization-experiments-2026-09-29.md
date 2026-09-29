# Optimization experiments, batch 2

Three lower-confidence candidates were implemented with Luna/Sol assistance,
reviewed, measured against the audited `4517152` implementations, and retained.
The preceding batch remains intact. No final candidate required reversion.

## Measured results

Five alternating paired samples in fresh task processes, using the default 16 MB
TUI cache budget. Times are medians from the final run, not production guarantees.

| Workload | Before | After |
| --- | ---: | ---: |
| 64 KB Markdown tail, 40 visible rows | 104.18 ms | 37.02 ms |
| Long syntax-highlighted code tail | 317.99 ms | 95.49 ms |
| 400-record table tail | 198.82 ms | 43.31 ms |
| Long heading tail | 16.37 ms | 12.85 ms |
| Literal index, serialized size | 6,825,913 bytes | 265,113 bytes |
| Literal index cache residency | Rejected | Cached |
| Repeated 40-row viewport over 20,199 rows¹ | 33.39 ms | 0.645 ms |
| 1,000-line disjoint diff, 128-byte preview | 433.09 ms | 2.124 ms |
| 1,000-line mostly shared diff | 2.128 ms | 2.128 ms |

¹ Times only the viewport request after building the index, including any
rebuild caused by cache rejection. Cold index construction also improved,
34.25 ms to 18.46 ms.

## Changes and acceptance criteria

- **Markdown:** blocks of at least 8,192 bytes use the existing native row
  measurement and window renderer, exporting only the requested styled rows.
  Layout construction is shared with the existing indexed path. Exact styled-row
  tests cover prose, code, headings, tables, Unicode, separators, and repeated
  calls. Review rejected an uncached long-tail variant; the final version caches
  visible tails under the existing shared byte budget. It still measures the
  whole block; this is not constant-time streaming layout.
- **Literal indexes:** store wrapped strings rather than a `Line` and `Span`
  structure per hidden row. Reconstruct styled structures when a caller asks for
  windows or plain groups. Atom Markdown roles retain their existing layout
  path; non-atom Markdown roles preserve their previous full-render behavior.
  Tests compare mixed-entry windows, text, offsets, expanded details, Unicode,
  string and charlist roles, and cache residency.
- **Diff:** for at least 64 combined lines, detect completely disjoint line sets
  and emit the same deletion/insertion groups Myers would return. Shared-line
  cases still use Myers. Differential tests compare exact patches against the
  previous implementation, including empty sides, repeated/shared lines, cutoff
  boundaries, tiny previews, and missing final newlines. This does not bound the
  worst-case computation for partially overlapping files.

Small and boundary workloads were also measured. The 8,200-byte Markdown case
was effectively flat (6.84 versus 6.98 ms), while 12 KB improved (11.77 versus
9.49 ms). Cached 64 KB tail calls remained cheap (0.093 versus 0.063 ms).
The diff membership check adds linear work on shared inputs: one earlier run
showed approximately 0.10 ms overhead at 1,000 lines, and the final 250-line case
showed 0.043 ms overhead. The large disjoint-case gain justifies that measured
tradeoff; no claim is made that every workload becomes faster.

## Validation and limitations

- Core: **1,160 tests, zero failures**, with `--max-cases 1`, 85.8 seconds.
- TUI: **217 tests, zero failures**, with `--max-cases 8`, 9.0 seconds.
- Both used `mix test --preload-modules --seed 337473`.
- Two earlier core runs at concurrency 8 failed different unchanged tests:
  worker/writer process-death races, then Codex messaging. The first two passed
  focused reruns and the next full run; all passed the sequential full suite.
  This is evidence of timing sensitivity, not proof that concurrent tests are
  now reliable. No unrelated tests or production paths were changed to hide it.
- Changed files pass formatting and `git diff --check`.
- No live-provider or interactive terminal session was used. Serialized index
  size is not OS RSS. This batch reduces allocations and repeated work; it adds
  some branch logic and does not claim a net SLOC reduction.

[Reproduction script](../scripts/optimization_experiments.exs) and
[raw measurements, including earlier runs and failed validation attempts](measurements/optimization-experiments-2026-09-29.json).
Run the script from `packages/alto_tui` with
`mix run ../../scripts/optimization_experiments.exs`.
