# Alto / Space Bunny stress test — 2026-09-27

Work was merged into master and continued in the main Alto checkout. Live model: `stealth/space-bunny-alpha` through OpenRouter. Test workspace: HotLimit, a pure-C/SDL3 sketching application. API credentials were resolved only into HTTP authentication, not prompts or artifacts.

## Addressed findings

- Failed-task history: display loads the saved conversation revision independently of execution-resume fencing. Verified against copies of the two original HotLimit sessions.
- TUI model choices persist across tasks, providers, backends and restarts; welcome help duplication removed; Ctrl+G S promotes queued input in place.
- Unborn Git repositories: `unstage` now works without deleting files; branch creation before the first commit gives an explicit error instead of reporting a branch that does not yet exist. Git's unborn HEAD is normal, not repository corruption.
- Codex child startup: providerless rule-loop adapters no longer inherit a provider-only system prompt. The regression check reaches the external adapter instead of failing with `prompt_options_require_provider`.
- Hierarchy: the router, not message text, attributes parent/ancestor/child/peer relationships. Parents can redirect delegated work within the user's scope; peer messages remain context.
- TUI subagents: Ctrl+G U opens a live, filterable agent picker and separate child activity/results. Duplicate labels remain separate through stable IDs. Esc leaves inspection without cancelling the parent.
- Tool argument validation: an unloaded tool could bypass validation via `function_exported?`. The preparation boundary now loads the trusted module before checking callbacks.
- Result semantics and sandbox boundaries are documented: verdict tracks tool-effect evidence; request counts include failed provider attempts. Bubblewrap intentionally exposes read-only system files and has ephemeral outside-workspace writes. The observed 402 was model/account-specific, not an OpenRouter-wide outage.

## Automated validation

- Core: 1,084 tests pass with `ERL_FLAGS='+S 4:4' mix test --max-cases 1`.
- TUI: 173 tests pass.
- Under parallel load, separate runs exposed a 10 ms file-lock timing assertion and a 600 ms tool-start assertion. Both pass in isolation and in the full serial run. No runtime behavior was changed merely to hide these timing failures.

## Live observations

- First coordinator request timed out at the configured 120-second total HTTP request deadline during planning. The session persisted successfully and was resumed.
- Resumed coordinator started two real Space Bunny workers, with separate core and SDL-shell ownership. Both emitted stable-ID lifecycle and tool activity and wrote implementation files.
- The coordinator then stalled and hit a 300-second request deadline. Its owned children were cancelled as designed. A child correctly reported a header compile blocker, but the coordinator never reached another safe model boundary to act on it.
- This remains a provider/coordination resilience limitation: an active stream can hit the configured total deadline, and a failed parent owns child cancellation. Increasing timeouts alone did not fix this run. A single model worker under a local controller completed the implementation and delivery checks described below.

## Completed live delivery checks

- Parent steer was router-attributed as `parent`, consumed once, and acknowledged with `HIERARCHY_ACK` plus the revised implementation priorities. Replaying the same idempotency key returned the same message ID.
- Queued follow-up was consumed after the initial work. The worker wrote `FOLLOW_UP_CONFIRMED` and reran the build/tests. It reached the configured 75-request limit before sending its final parent summary. This is a failed run with useful saved work, not a successful run disguised as one. Provider usage records 75 requests; the runner records 76 attempted steps including the rejected next step.
- Session `sess-bdj3hqt4f2mld5y` persisted successfully and is registered under HotLimit as **Space Bunny: integration and hierarchy verification**. Its failed-state history remains readable.
- The earlier multi-agent coordinator session is `sess-4z26z4ngti6et6q`. Two real children wrote the brush core and SDL shell, with live lifecycle/tool events and stable IDs.

## Additional Alto fix from the live run

Explicit relative executables such as `./build/dbg` were resolved against the host VM cwd instead of the task cwd. Resolution now uses the task workspace before approval, preserving the resolved path during execution. A regression executes both `./build/probe` and `build/probe` from a different task directory. All 27 targeted command/Git tests passed after this change.

The model also repeated the executable inside `args`, producing `make make`. That is a model argument error, not an executor PATH bug. The schema now gives explicit argv examples. Its generated report initially misattributed this failure; the reviewed report corrects it.

## Sketching application delivered

The source is in `/home/three/code/HotLimit`: a pure C11 CPU brush/canvas core, SDL3 mouse/pen shell, size/spacing/hardness/opacity/flow and pressure scaling, eraser, bounded snapshot undo/redo, and 24-bit BMP save/load. Keyboard controls and build steps are in its README. This is an initial sketching prototype, not a full SAI/Clip Studio brush engine. Layers, textured tips, stabilization, zoom/pan and stroke-level opacity accumulation remain outside this prototype.

Space Bunny fixed the compile blockers, inverted falloff, inaccurate custom square root, zero-pressure painting and part of the undo implementation. Independent review then reproduced and fixed bugs its passing suite missed: one stamp beyond the output capacity, undo after redo, an unintended diagonal in multi-segment strokes, rectangle integer overflow, translucent-color wraparound, signed top-down BMP height, and one-pixel brush taps. Pen events now receive the same coordinate conversion as mouse events; synthetic pen-to-mouse duplicates are ignored.

Validation after those fixes:

- `make all test smoke`: 256 original checks, separate independent regression suite, BMP/undo/redo self-test, and actual SDL window/renderer/texture tests with synthetic mouse and pen events, all pass.
- Both core suites pass AddressSanitizer and UndefinedBehaviorSanitizer with leak detection enabled.
- The SDL-rendered synthetic stroke was captured and visually inspected. The dummy video driver was used; physical pen hardware, a real display/HiDPI setup and long drawing sessions remain untested.
- SDL3 3.2.10 headers/runtime were extracted locally into ignored `.deps/usr`; no system installation or dependency binaries were committed. The existing license and staged `.editorconfig` were preserved. App source is left in the HotLimit checkout, with no invented Git identity or commits.

## Remaining issues to track

1. **Provider/parent resilience:** the remote coordinator twice timed out (120 seconds, then 300 seconds); parent failure cancels owned children. A richer recovery policy needs deliberate design. The failed history and partial artifacts remain available.
2. **Model efficiency and test quality:** integration consumed 75 provider requests, and its passing tests missed important cases. In one redo test the model reset the canvas between phases, masking a broken transition. The independent regression now checks undo → redo → undo directly.
3. **Activity after restart:** the new TUI inspector retains bounded live activity for the current UI session; historical child sessions are durable, but reconstructing the inspector from them is not implemented.
4. **Timing-sensitive tests:** the existing 10 ms mailbox lock and 600 ms tool-start tests failed under parallel contention. The complete serial core run passed. These should be stabilized separately rather than changing production behavior to satisfy wall-clock assertions.

