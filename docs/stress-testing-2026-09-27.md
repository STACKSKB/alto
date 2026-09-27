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

## Large-write preparation fix

UI integration attempted a legal 58,399-byte `write_file`, but preparation failed with `approval_details_limit` at 64,000 bytes. The protected-path wrapper was an identity transform; the shared tool boundary nevertheless copied all unchanged arguments into the bounded approval details in addition to the preview/diff. The generic fix compares transform output with the original input before defaults/validation: unchanged inputs are not redundantly copied, while genuinely transformed values remain fully visible for approval. No approval or file-size ceiling was raised. Eight targeted tests passed, including protected-path denial and changed-transform metadata. The exact rejected write was recovered from its saved model tool call and replayed through a fresh fixed Alto rule loop; session `sess-hfxp2o4dm4wfoey` completed successfully and the written bytes matched exactly.

The ink worker `sess-bunappmmxj6yhky` completed in 11 requests and independently passed 3,969 checks with sanitizers. Subsequent review and direct reproduction found two remaining app edge cases outside that suite: stationary pressure increase from zero can disappear, and default stabilization can pull ink across a zero-pressure lift. These are being delegated for correction; passing that suite alone is not app acceptance.

The complete core suite after the preparation fix passed **1,103 tests** with ordinary parallelism. Application workers were then relaunched against this tested code.

## Actionable ambiguous edits

Repeated ambiguous `edit_file` failures exposed insufficient recovery information. Errors now report the one-based batch edit index, total matches, and at most eight matching source line numbers with a truncation flag. Guidance asks for unique surrounding context and reserves `replace_all` for intentional changes to every occurrence. Exact matching and atomic application remain intact. All 31 workspace tool tests passed, including batch atomicity and bounded diagnostics.

Live Space Bunny probe `sess-2ogqblwbfbdh4ea` deliberately submitted an ambiguous edit, received lines 2 and 4, retried with unique context, and verified only the second value changed. It completed successfully in five model requests.

Independent ink verification now passes **3,989 checks** under address, undefined-behavior and float-cast-overflow sanitizers. Direct stationary-contact and stabilized pen-lift reproductions also pass. Document compilation and UI integration remain unfinished; these results do not establish application acceptance.

## Explain byte caps on source-line reads

A resumed workload requested `start_line: 378, limit: 40`, receiving only 40 bytes of the first source line despite schema guidance. Line-mode results now explicitly report returned bytes, the output byte limit, and whether that limit cut the requested range. A conditional recovery hint distinguishes `limit` from `line_count` and explains safe byte continuation without mixing units. Bounds and existing continuation semantics remain unchanged. All **32 workspace tool tests** passed. Live probe `sess-5pgoooqxgiiu3pi` received the diagnostic, retried with `line_count: 2`, retrieved both complete lines, and finished in four requests.

Workers were stopped with saved sessions `sess-wyihfmigwuqjuea` and `sess-iktunyudh6qxsjq` before the fix. The next fresh processes resume those conversations rather than repeating their investigation. An independent fresh document build now succeeds but its suite still reports **716 checks, 40 failures**. UI testing exposes incorrect layer control dispatch, pressure loss on point-drag press, and incomplete live stroke previews; these are application fixes still in progress.

## Unsupported argument diagnostics

The UI worker supplied `max_output_tokens` to `run_command`; the generic validator rejected it with only `unknown_tool_argument`. The shared validation error now names bounded unsupported fields and accepted fields, with a correction hint. Argument values are excluded; non-string keys use a fixed label and long UTF-8 names are clipped at a valid byte boundary. Rejection still occurs before dispatch. All **45 impacted tests** passed, including Unicode and many-field bounds. Live probe `sess-vsz663vmldnycma` corrected the unsupported request and successfully ran `pwd` in three requests.

The paused application snapshot independently passes 256 core checks, the regression suite, 3,989 ink checks and **717 document checks**. Document checks also pass address/undefined-behavior/float-cast-overflow sanitizers. The SDL UI suite still has one undo assertion failure; application acceptance and complete history-bound behavior remain pending.

## Unknown-tool recovery and integration validation

A live worker requested an unregistered `bash` tool. Unknown-tool errors now retain the requested name and add a bounded sorted list of tools registered for that run, plus a schema-following hint. The list uses only the actual run's capability map; an empty subagent override discloses no parent tools. All **28 impacted tests** passed. Live probe `sess-cdhh6hwrm4fju7a` used the registered command tool instead of making the requested invalid call, so it did **not** validate the unknown-tool branch.

Before this final diagnostic change, the full Alto core suite passed **1,107 tests**. Document session `sess-wyihfmigwuqjuea` completed with successful persistence. Independent fresh fault-injection verification passed **2,906 checks** with address, undefined-behavior and float-cast-overflow sanitizers. The agent's report of partial/empty line reads was not supported by its completed v8 trace: all eight reads returned their requested line counts without partial lines or byte-limit truncation.

Actual SDL renderer capture found UI defects beyond state tests: mismatched numeric formatting, text painted under control faces, staircase rows, and reused label buffers. Space Bunny is fixing those. A separate lifecycle review found a selftest canvas reinitialization leak, also pending correction. UI completion and physical pen feel are not claimed.

## Verified document/UI milestone

UI session `sess-iktunyudh6qxsjq` completed with successful persistence after resumed runs on fixed Alto. Independent host validation passed `make all test smoke document-fault-test`: core256, regressions, ink3989, document913, actual SDL event/UI tests, application selftest/BMP/project round-trips, and injected document2906 checks. A fresh independent SDL UI binary also passed address, undefined-behavior and float-cast-overflow sanitizers with leak detection enabled.

Fresh SDL renderer readback confirms distinct correct brush values (size6, opacity100%, stabilization55%), knot labels1–5, visible layer names and compact aligned controls. This is a headless software-renderer check, not physical tablet feel acceptance. The next realistic workload is true blended tip composition plus retained-brush persistence, followed by UI wiring; existing parallel tracks are not counted as that feature.

Recurring model mistakes remain observable despite improved guidance: repeated executable arguments, shell wrappers that mask status, and stale messaging IDs after process resume. Recovery diagnostics improve correction but do not establish that initial error frequency is acceptable. The file-read allegation from the finished document run was unsubstantiated by its eight complete recorded line reads.


## Mixed-tip workload milestone

Space Bunny completed bounded engine/document and UI workloads in saved sessions `sess-gix3nayrc63hwjq` and `sess-6bcvre5jilwbhnq`. HotLimit now supports up to four weighted round/ellipse brush components, editable component settings, explicit application to a selected vector stroke with undo, and versioned project persistence that retains compatibility with older projects. This is analytic tip blending; bitmap textures and physical tablet feel have not been validated.

Independent `make all test smoke document-fault-test` passed: 256 core checks, the regression suite, 4,168 ink checks, 1,025 document checks, 3,018 allocation-fault checks, the SDL dummy-driver UI suite, and the application self-test. Fresh ink and UI builds also passed address, undefined-behavior, float-cast-overflow, and leak checks. Rendered brush samples and the mixed-tip control panel were inspected. Review caught and corrected ellipse coverage/bounds, tiny round-dab coverage, and maximum component-radius clipping before this verification. Allocation injection covers malloc, not independently calloc/realloc.

Repeated argv mistakes, an unregistered Bash tool request, and failure-masking shell wrappers remained harness usability findings despite earlier prompt improvements. All application workloads were terminal before beginning a general explicit-shell tool improvement.

## Explicit shell execution and honest command status

Added opt-in `run_shell`, registered in the shipped agentic profile, for a single bounded shell script. It prepares Bash `-e -o pipefail -c` through the same command executor, sandbox, approval, timeout, and output boundaries as argv execution. `run_command` remains compatible. Conditional prompt guidance and schema examples distinguish the contracts and explain Bash failure-propagation exceptions. Shell previews are bounded. The shared TUI/history display now marks nonzero command exits and timeouts as errors instead of showing a success check mark.

The complete core suite passed **1,116 tests** and the TUI suite passed **175 tests**. Live Space Bunny session `sess-2pj7jak2t5wdgzy` used the new shell tool inside Bubblewrap: `false | cat` returned exit 1 and the following unexpected-success marker did not execute. It then used direct argv execution for HotLimit `make test`, which passed, and accurately reported both outcomes. The run completed in three model requests with persistence confirmed. This validates the tool contract and one live recovery path; it does not establish that all model command mistakes are eliminated.

## Interrupted navigation workload and missing-edit recovery

Fresh fixed Alto session `sess-nip2tewevjuio3q` began realistic HotLimit zoom/pan work. It used `run_shell` for a build pipeline and correctly received exit 2 from a compiler failure rather than a masked success. A subsequent edit failed with only `text_not_found`; the general edit diagnostic now identifies the one-based failing replacement and instructs rereading current contents and using exact context. Batch atomicity remains intact; all 32 workspace tool tests passed.

The provider terminated request 18 with HTTP 429, identifying its free-model daily cap (1,000 requests, zero remaining), with reset at **2026-09-28 00:00 UTC**. The conversation persisted; no repeated retry or provider substitution was attempted. The incomplete navigation source was retained. A local correction replaced an unsupported SDL wheel-event field with `SDL_GetModState`; existing `make all test smoke` then passed. New navigation tests, gesture edge cases and feature documentation remain unfinished, so this is not navigation acceptance. Live Space Bunny validation of the missing-edit diagnostic must wait until provider access resumes. Codex usage was separately checked at 12:25 UTC and had 45% remaining.

An offline recovery check of that actual failed session successfully loaded resume options and retained 41 messages (17 assistant, 21 tool, two user, one system). The shared history renderer produced 39 entries, and the catalog retained the failed Alto task with its correct conversation ID. No provider request was made. This verifies durable history and resume preparation for this 429 run; an interactive workspace-close/reopen test is a separate scope.

## Free-model rate-limit recovery

Alternative free-model runs exposed distinct upstream-capacity and per-minute limits. Alto's existing three retries used sub-five-second jitter, exhausting attempts before a minute reset. The shared HTTP boundary now retains only normalized Retry-After/reset timing for 429/5xx errors; transient policy honors that minimum without jitter shortening and stops automatic retry above 60 seconds. Cancellation, total run budget, partial-output protection and request accounting remain on the existing runner path. Retry events now carry delay_ms, shown in parent/subagent TUI activity. Errors without timing retain their previous shape.

Full core tests passed **1,122** and TUI tests **176**. Regressions cover date/delta/epoch hints, malformed input, long waits, cancellation, deadline and partial-stream protection. A fresh Qwen free-model probe hit upstream capacity limits without a timing hint; Cohere session `sess-duvsmnssgnog3bi` completed a real read_file smoke test in two requests. This is live tool-path validation, not a claim that a live timed 429 recovered.

## Independent review and pen-latency steering

Sol reviewed recent retry/persistence changes. HTTP dates already use Req.Utils.parse_http_date; the bounded wrapper is retained because Req.Response.get_retry_after uses wall-clock time and can raise on malformed input. Review found a real fallback bug: malformed HTTP hints suppressed valid body hints. Candidate hints now validate before selection, and duplicated metadata-delay extraction was consolidated. Thirteen impacted core tests passed. Preferences remains a small shared-Storage wrapper, not a custom serializer; moving it into Catalog would add migration/coupling. Sol also found and fixed provider-form saves overwriting a selected model when editing labels/credentials. Explicit default-model changes still select that default. The complete TUI suite passed 177 tests.

Luna traced HotLimit pen latency to full-document raster replay per sample and full-page coverage allocation per stroke. Its local 1024x768 three-run composite means were 5.1 ms empty, 6.2 ms with eight two-point strokes, and 14.6 ms with 32. Smoothing/tapering means naive append-only live rasterization can change output; cache committed work first. These findings were delivered as staged parent steers to free Cohere through Alto. Initial 64k stress cap plus 12 retained messages left no compactable middle; this was stress-profile retention, not absent compaction wiring. At 96k with two recent messages, session sess-gdfjmbults25o3q completed one Handoff compaction, then had no-progress and invalid-JSON compaction failures. It was cancelled with persistence before further Alto fixes. Pending queued steering must be re-delivered on resume; full constraint retention and repeated compaction are not yet verified.
