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
3. **Activity after restart:** addressed in the follow-up below; the inspector now reconstructs saved child activity.
4. **Timing-sensitive tests:** addressed in the follow-up below; the full suite now passes with ordinary parallelism.

## Follow-up: Alto reliability under the manga workload

The user clarified that HotLimit is a realistic test workload; Alto reliability remains the priority. Multiple/blended brush tips (not parallel tracks) are the intended app direction. Layers and the editing UI remain future workload steps.

### Fixed in this follow-up

- **Saved subagent inspector:** native tasks reconstruct child/grandchild activity, results and session IDs after restart. Separate child sessions are discovered independently of the recent-100 session list; shared-session child runs are also supported. Failed/cancelled results remain readable behind an execution resume fence. A missing completion is marked `no saved completion`, without assuming the process is running or finished. Discovery is bounded to 4,096 headers and 256 child entries, with truncation/read-error notices. Uncommitted streaming fragments cannot be recovered.
- **Real history verification:** reopening coordinator session `sess-4z26z4ngti6et6q` restored both `core` and `shell` with cancelled statuses and retained activity, without warnings.
- **Streaming deadlines:** HTTP adapters now accept an optional `idle_timeout`. Existing `timeout` remains a hard total deadline; existing configurations retain their previous behavior when the new field is absent. The agentic profile uses 120 seconds of silence, 600 seconds total and a 610-second runner deadline (the remaining run budget can end it sooner). Tests use a real local HTTP stream to verify continued activity, silence timeout and an unextendable total deadline.
- **Recoverable addressing mistakes:** Space Bunny dropped the `agent-` prefix three times and misreported this as a router failure. The tool now explains the exact-address requirement and suggests the complete registered address when the prefix was omitted. It never reroutes automatically. In live session `sess-ovecm7q6nzglbyy`, the model corrected the address and delivered exactly one `RECOVERY_ACK` in four requests.
- **Closed stdin for finite commands:** the review worker twice ran `grep` without a file target and waited for a 30-second timeout. Although the missing target was a model mistake, a noninteractive executor should supply EOF. Finite commands now receive `/dev/null` after the startup handshake, including sandboxed execution and the degraded process-group fallback. Retained stdio clients keep their writable input. Regression tests cover `cat`, `grep`, degraded startup and sandboxed commands; existing interactive handshake/MCP tests remain passing.
- **Timing-sensitive tests:** file-lock tests no longer compete with the async suite for a 10 ms subprocess startup window; the mailbox timeout check uses 100 ms. The serial tool-start test allows a bounded 5 seconds for startup while retaining its serialization assertions. Production locking/scheduling semantics were not relaxed.

### Validation

The final complete core suite passed with ordinary parallelism: **1,094 tests**, `ERL_FLAGS='+S 4:4' mix test` (8 cases). The full TUI suite passed **174 tests**. A subsequent inspector change also reports truncation for shared-session children; that regression and all application tests passed together (**60 tests**). The focused command/process/sandbox suite passed **37 tests**, including retained stdio behavior. `git diff --check` passed.

### Live workload and remaining limits

Space Bunny implemented a retained manga-ink engine in `HotLimit/src/ink.c` and its tests. Session `sess-27ciha4rpee427i` completed successfully in 30 requests, with 884 checks reported passing. Independent review found additional app defects despite those tests: color alpha was ignored, straight-alpha erasing darkened RGB, self-clone destroyed the source, short two-point strokes disappeared, huge finite inputs could overflow arithmetic, and general monotonic pressure curves were not guaranteed monotonic. The second bounded Alto workload, session `sess-jh325uw5tvqdwei`, fixed those cases and completed successfully in **34 requests** with successful persistence. It also removed an invented straight shortcut when the subdivision budget was exhausted.

Independent host validation passed `make all test smoke`: the original 256 checks, the separate regression suite, **3,926 ink checks**, BMP/undo/redo self-test and SDL synthetic mouse/pen smoke tests. A fresh build of the ink suite also passed all 3,926 checks under AddressSanitizer, UndefinedBehaviorSanitizer and float-cast-overflow instrumentation. Both workload sessions are registered in the HotLimit task catalog.

The engine remains separate from the window. Layers, a vector-editing UI, mixed brush tips, physical-tablet tuning and G-pen feel are not claimed complete. Parent failure still cancels its owned children; automatic orphan recovery or replay of uncertain tools is not introduced. New timeout settings reduce avoidable two-minute total timeouts but do not make a stalled remote provider reliable. Partial work remains inspectable.

## Continued workload: tool ergonomics

The next document/layer and ink-input workers repeatedly used byte offsets as line numbers, split a grep pattern across argv items, and duplicated the executable in args. Treating these only as model mistakes misses an interface problem: file search returns line numbers while file reading previously only accepted bytes, and displayed offsets omitted the unit. Both workers were cancelled with saved sessions (`sess-o2aeausnapm3bhq`, `sess-lg3fyglbzmmmw7q`) before continuing on improved Alto.

General fixes, independent of model/workspace/run:

- `read_file` accepts 1-based `start_line` and `line_count`, matching search results. Existing byte reads remain compatible. Both modes retain the output byte ceiling; line scans also have a bounded host-configurable ceiling. Results state their units and return continuation positions; partial lines continue by byte offset without silently skipping their remainder. Conflicting units fail clearly.
- Tool titles label byte offsets versus line ranges and show command argument boundaries faithfully.
- The coding prompt and schemas explain one argv item per argument, literal search phrases, explicit shell syntax, and checking executable availability. Capability-specific instructions appear only when the corresponding tool exists. Commands are not silently rewritten.

Validation: 1,097 core tests passed, including line-range continuation, byte ceilings, scan boundaries and binary data. Targeted prompt/display tests passed. Live verification with restarted workers follows.

The next live run used source-line reads correctly, but still called `ls` with `args=["ls"]`. The workers were stopped again before a second general fix: completed nonzero command results now include a structured recovery hint when the first argument repeats the executable. Output and exit status remain intact; legitimate successful repetitions are unchanged, and Alto never rewrites/retries the command. All 27 targeted command tests passed. Live probe `sess-gdr7fprkwu5jzfi` corrected `ls ["ls"]` to `ls []` after reading the hint and completed successfully in three requests. The complete TUI suite also passed 175 tests after the line/display changes. Both app workers were relaunched in new Alto processes with these fixes.

A further prompt defect was caught during development: the illustrative `make test | tail -20` pipeline could hide a failing test's exit status. Workers were stopped before correcting the shared guidance. Tool descriptions and the coding prompt now use valid JSON examples, show direct execution of compiled binaries, explain exact argv strings and timeout bounds, and require preserving test failure status (including `pipefail` for necessary Bash pipelines). The 25 targeted prompt/command tests passed. Independent direct sanitizer runs on the interrupted app snapshot correctly reported pending app failures: two ink lift-boundary failures and 40 document-history/compositing failures; these are not passing application results. The app workers are being relaunched to resolve them before UI acceptance.
