# v0.0.2 source release

Target: Linux, Elixir 1.18 / OTP 27. Build from the tagged checkout; no binary
artifacts or CI workflow are part of this release.

Release checks:

- Root formatting check and production compilation with warnings as errors.
- Complete core and optional TUI test suites.
- Clean tracked-source build: production CLI compilation, escript build and help.
- Clean optional TUI build, including native dependency installation.
- Providerless source-consumer run; optional TUI remains absent from core.
- Regression coverage for failed history, restored child activity, model choice,
  queued-message promotion, cancellation, and repeated handoff/steering.

The repeatable handoff/steering gate uses a scripted provider with the real
runner, input channel, tools, session persistence and Handoff reducer. This tests
harness delivery and compaction contracts, not an arbitrary model's ability to
summarize correctly. Live free-model runs exercised parent steering, successful
compaction, malformed/no-progress handoffs, and server-directed retry waits;
continued live testing was stopped by the provider's daily quota.

Known limits are listed in CHANGELOG.md. In particular, TUI queued input is
in-memory, and an invalid model-generated handoff can fail compaction. HotLimit
is a separate stress workload and is not included in this source release.

Verified on the release source: 1,126 core tests and 177 TUI tests passed.
Formatting, production warnings-as-errors compilation, clean CLI/TUI builds,
escript help and the source-consumer smoke check also passed.
