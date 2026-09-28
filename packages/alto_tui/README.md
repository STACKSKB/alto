# Alto TUI

`alto_tui` is Alto's optional terminal UI example. It keeps the native ExRatatui
dependency outside the core production build while using the same host-owned
approval, execution, cancellation, session, and protocol boundaries.

From an Alto checkout, run the working example profile with:

```sh
cd packages/alto_tui
mix deps.get
mix alto.tui --config ../../alto.agentic.exs
```

The existing `rustler_precompiled` dependency is pinned and patched at build time
to replace native libraries atomically. Its unpatched extraction can crash a
running TUI with `SIGBUS` when another build overwrites the mapped library.
For a checkout built before this fix, rebuild that dependency once in each used
environment: `mix deps.compile rustler_precompiled` and
`MIX_ENV=test mix deps.compile rustler_precompiled`. Fresh builds apply the patch
automatically; no new dependency or native toolchain is required.

While the TUI is open, standard console Logger handlers are muted and logs go to
`$ALTO_STATE_HOME/alto/logs/tui.log` (or `$XDG_STATE_HOME/alto/logs/tui.log`, defaulting
to `~/.local/state/alto/logs/tui.log`). Use `--log PATH` to choose another file, or
pass `log_path: PATH` to `Alto.TUI.run/2`. Logs rotate at 5 MB with three archives.
Console logging is restored when the TUI exits, including after a run-time failure.
Existing file handlers remain active. Custom handlers must also avoid writing to
the terminal while it is in use.

The example profile's request-prefix diagnostics are opt-in: set
`ALTO_REQUEST_DIAGNOSTICS=1` to include them in the log. Debug messages, warnings,
and errors never belong directly on the active TUI screen.

The example hosts runs locally in its process tree. A separate application can
reuse the UI components and connect them to a persistent service through Alto's
transport APIs. The profile and maintained application examples are documented in
[`examples/README.md`](../../examples/README.md).

Press Enter to send a message. While a turn is running, Enter queues one follow-up
for that task; it starts after the current turn succeeds. A second follow-up
stays in the composer until the queued message has started. Queued messages are
kept in memory for the lifetime of the TUI.
Press **Ctrl+G, S** to turn the queued follow-up into a steer, delivered at the
next safe model boundary after dispatched tools settle. This keeps your current
draft intact. **Ctrl+Enter** sends a draft as a steer; with an empty draft it
promotes the queued follow-up. Steering requires a backend that supports it.
Pending messages appear below the current response and in the context pane.
When delivered, their queue notice disappears and each message becomes a separate
`you ›` turn before its response, including when native input continues the same run.

Provider and model choices are remembered across tasks, workspace switches, and
TUI restarts. Each backend/provider pair keeps its own model choice.
Saved task history remains viewable after a failed run, including when an
unfinished tool dispatch prevents safely resuming that run.

The status bar shows whether Alto is waiting for the model, executing a tool, or
waiting for approval. Click the labeled Approve or Deny buttons, or press F8 or F9,
to answer a pending request. Esc stops the selected task's run and preserves your
draft. If a popup or the compact details
drawer is open, the first Esc closes it. Cancellation, failure, or a session-save
failure pauses the queued follow-up; press Enter with an empty composer to send it.

**F2** opens approval choices: ASK, READ, AUTO, and **REVIEW · approve for me**.
An explicit choice overrides the configured native approval policy. AUTO also
resolves waiting approvals immediately. The native TUI consults the current
choice for subsequent requests, including child runs. Codex sandbox changes take
effect on its next turn; requests already reaching the TUI use the current choice.

Configure any two-argument approver in your Elixir config (`alto.exs`, or the file
passed with `--config`), then select REVIEW:

```elixir
tui: [
  approval_reviewer: fn request, context ->
    MyClassifier.approve?(request, context)
  end
]
```

The callback receives the prepared request (`id`, `run_id`, `call_id`, `tool`,
`arguments`, `execution_mode`, `details`) and execution context. It may call an
LLM, a local classifier, or ordinary Elixir logic. Return `true` / `:approve`, or
`false` / `{:deny, reason}`. Exceptions, invalid decisions, and timeouts do not
approve the request. `approval_timeout` bounds review time; cancellation cleans
up pending reviews. Native callbacks receive the runner's tool context; Codex
callbacks receive `cwd`, `session_id`, and `metadata`. REVIEW requires a callback
and does not silently fall back to AUTO.

**Ctrl+G, G** opens the task goal editor. Enter an objective and press Enter to
save it on the selected task, creating a task if needed. The editor shows the
current status and provides **Pause**, **Resume**, **Complete**, and **Clear goal**
actions. Use Tab or arrow keys to select an action, then Enter; Esc cancels.
The chat draft stays intact. Goals survive TUI restarts and appear in the context
pane. Active objectives accompany the next run's initial message on either
backend. Goal controls do not start, cancel, or automatically continue runs;
changes during a run apply when the next run starts.

Assistant replies and reasoning render Markdown headings, emphasis, and code.
Tool output uses a six-line, 1,200-byte preview with an explicit truncation
marker. Opening search exposes the longer retained tool details; closing search
restores compact previews. The model and session keep their original tool results.

**Ctrl+F** searches the current loaded conversation, including user messages,
assistant replies, code, and tool/edit details. Matching is literal and
case-insensitive; punctuation has no special meaning. Type or paste a query,
then use **Enter / Shift+Enter**, **F3 / Shift+F3**, or **↓ / ↑** for next/previous
occurrence, wrapping at the ends. **Ctrl+U** clears the query; **Esc** closes
search without sending the draft or stopping a run.

During search the context side panel shows matching excerpts beside the
conversation and draft. **Tab** or **Ctrl+G, D** moves between results and the
conversation; on narrow terminals it opens or closes a results drawer. Clicking
an excerpt jumps to its position and closes the narrow drawer. Esc restores the
previous context visibility and focus. Pending approvals keep priority over search;
a new approval closes search while respecting the automatic-opening preference. The bottom bar always shows **Prev / Next / current/total**
controls, including when context is hidden or the terminal is narrow. Visible
matches are highlighted; matches in Markdown source syntax that has no visible
glyph remain available as excerpts in the results. Resizing does not change
the occurrence count. Search is temporary TUI state, clears when switching
tasks, and never becomes agent input or a persisted session event.

Host configuration uses `%Alto.Harness.ProviderProfile{}` entries in
`provider_profiles`, with a `{module, options}` provider and either `:discover`
or atom-keyed catalog maps:

```elixir
provider_profiles: [
  %Alto.Harness.ProviderProfile{
    id: "local",
    provider: {Alto.Providers.OpenAICompatible, base_url: "http://localhost:1234/v1"},
    models: [%{id: "coder", name: "Coder", context_length: 32_000}]
  }
]
```

Omitted labels and credential IDs use the profile ID; an omitted default model
uses the provider's `:model` option. Explicit profiles do not accept map/keyword
shorthands or string-only model catalogs.

Forms share the menu navigation: use Tab or Up/Down to select a field or action.
The selected field is edited above the list; Left/Right moves its cursor. Enter
advances to the next field or submits the last field, and Ctrl+S submits directly.
API keys stay masked. Folder forms use Tab for path completion.

While a run is active, the conversation border shows an animated stage and elapsed
time, including waiting for the model, thinking, receiving text, running tools,
and retrying a connection. Codex connection and model-catalog waits are visible too.

**Ctrl+G R** opens reasoning effort for models whose catalogs advertise choices.
The clickable `R:` setting shows the current value; choices are remembered per
backend/provider/model for this TUI session and apply to the next turn. Provider
default restores the provider's configured behavior. Unknown capabilities do not
get guessed effort values. For explicitly configured model catalogs, add an
`efforts: ["low", "high"]` list using the provider's supported values.

Readable provider reasoning appears as `thinking ›` before the answer and remains
selectable and available in saved history. Codex may supply summaries; encrypted
or redacted data is not displayed. The native Anthropic adapter emits thinking
when its complete response arrives; it is not a streaming adapter. Its provider
options accept `thinking: %{"type" => "adaptive"}` for models that support that mode.
OpenAI-compatible proxies can set `reasoning_format: :openrouter` when they expect
nested `reasoning.effort`; other endpoints use `reasoning_effort` by default.

Drag with the left mouse button to select conversation text, context data, your
composer draft, or entered form values. Selection stays inside its starting box.
Hold the drag at the top or bottom of a conversation/context pane to scroll;
scrolling runs at the same speed in either direction. You can also use the wheel while
holding the drag. Moving back inside or releasing stops autoscroll. Copy includes
the full selected range, including rows that have moved off-screen.
Controls, titles, status bars, and placeholder hints are not selectable by
default. Hold **Alt** while dragging to deliberately select UI text. Ordinary
clicks still operate controls, and dragging over a button never activates it.

**Ctrl+C** or **Alt+C** copies selected text. **Right-click without Shift** opens
a compact Copy menu with the shortcut shown in muted text. Selecting text does
not open a popup or toolbar. Esc dismisses the menu, then clears selection.
Ctrl+C without a selection retains its cancel/quit behavior. Ctrl+Shift+A selects
visible content; adding Alt explicitly includes UI text.

Selection freezes the rendered widgets and captures compact text once per gesture.
It reuses native buffers between gestures and indexes only boundary rows during
dragging. This avoids exporting every terminal cell or rebuilding conversation
history on mouse-down or motion. Long scrolled paragraphs are frozen to their
visible rows, so dragging does not reflow off-screen history. Run `mix run scripts/tui_selection_bench.exs` from the Alto
repository root to measure event handling plus native drawing.

Copy uses `wl-copy`, `xclip`, `xsel`, or `pbcopy` when available. Otherwise it sends
an OSC 52 request, including over SSH and through tmux; the terminal must allow
clipboard writes. The notice distinguishes a desktop copy from an unconfirmed
terminal request. Shift+drag and Shift+right-click are handled by the terminal,
so their behavior and native copy menu depend on the terminal application.

Paste with your terminal's usual shortcut (often Ctrl+Shift+V or Cmd+V). Bracketed
paste inserts text without submitting it, including multiline text and form fields.
Ctrl+V also reads the local clipboard using `wl-paste`, `xclip`, `xsel`, or `pbpaste`
when available; otherwise it inserts the last selection copied in this TUI.

Start a task with **Ctrl+G, N** in the current folder, or click a workspace name
in the sidebar to compose a new task in that folder. **Ctrl+G, T** also includes a New task action.

Click **+ New workspace** or use **Ctrl+G, W → Open another folder** to open a different folder. Enter an
existing folder path and press Enter (or click Open folder).
Relative paths start from the current workspace; `~` addresses your home folder.
Alto remembers the folder, selects it, and prepares a new task while preserving
your draft. Matching subfolders appear below the input as you type. Up/Down
highlights a suggestion; Tab copies it into the input, and Enter opens it. Continue
with Down to reach the action buttons, or use Tab when no further completion is
available. Click a
suggestion to copy its path and browse its subfolders. Tab extends the typed path to the longest common prefix of matching
folders. For example, `/hom` becomes `/home/`, regardless of the current workspace.
Use **Ctrl+O** or click **Choose folder** to open the folder chooser. Saved workspaces
appear when the field is empty; otherwise it lists filesystem matches. Type to
filter, use Up/Down or click a folder to copy it into the form, then press Enter to
open it. Esc returns from the chooser without changing the typed path.
**Ctrl+N** or **Create folder** creates and opens the typed path, including missing
parent directories. **Ctrl+U** clears the field.
The details pane stays beside the transcript and composer on wide terminals, and
its seam can be dragged to change its width. On narrow terminals it opens as a
drawer, with a full-screen fallback on very small terminals. Esc closes the drawer
and restores the previous focus. The details pane shows the full working folder. Existing runs continue
in their original folders. Use Ctrl+G, W to switch between saved workspaces.

Use **Ctrl+G, W → Create worktree…** to create a local linked Git worktree from
the selected workspace. Enter a name and a starting ref (HEAD by default).
Leave the branch field empty for a detached checkout, or enter a new branch
name. Creation uses committed files and leaves uncommitted source changes
untouched. On completion Alto opens a new task in the worktree and preserves
your draft; existing tasks continue in their original directories. Escape
dismisses the progress popup without cancelling creation or switching tasks
when it finishes. Worktrees and their ledger are stored beside the harness
catalog, outside the source repository, and remembered across TUI restarts.
Closing a workspace only hides it; it does not delete its Git worktree.

Close a workspace with the **×** on its sidebar row, **Ctrl+G, X**, or
**Ctrl+G, W → Close workspace**. Closing hides it without cancelling running work
or deleting files, tasks, or transcripts. Reopen its folder to restore its tasks.
You can close the last workspace and open another when ready.

Errors and returned tool data use readable messages and labeled fields. Provider
failures retain the HTTP status and supplied explanation; file and command results
show paths, exit codes, and output. Saved history uses the same presentation.
User and assistant messages retain their original code and prose.

Approval requests start at the top of the context pane, including when the next
queued request becomes active. Commands show the prepared command line, folder,
reason and execution limits. File changes show paths, replacement text and a
preview; other tools use readable labels. Approval still authorizes the original
prepared operation, not the display text. Context scrolling stops at the last
useful wrapped row, including after resizing or changing requests.

Large selections reuse cached interior-row rectangles and index their two boundary rows.
Highlighting changes cell colors without redrawing the selected text.
Consecutive mouse-motion events are coalesced before drawing, including remote
terminal sessions; releases, key presses, resize events and other messages keep
their order.

Model discovery loads provider modules before checking their capabilities, so a
fresh process can fetch the catalogue without a manual configuration round-trip.

## Backend composition

`tui_backends` is the complete ordered backend list. The UI no longer injects
native Alto or Codex entries. Existing custom-only lists remain custom-only;
include the built-ins explicitly when wanted:

```elixir
tui_backends: [
  alto: {Alto.TUI.Backends.Native, label: "Alto native"},
  codex: {Alto.TUI.Backends.Codex, label: "Codex · ChatGPT"},
  custom: {MyBackend, []}
]
```

The coding profile includes both built-ins. A saved task retains its backend
identity; if that backend is omitted, it cannot start until configured again.
New tasks select the first configured backend. Names are not reserved.

Runner adapters implement `Alto.TUI.Backend.start/4` and `cancel/3`. They receive
the catalog task, prompt, composed run options and backend options. Native Alto
uses this contract, including session resume. Existing custom runner adapters
need no new callbacks.

Interactive adapters implement `ui/3` and `cancel/3`. Codex uses this contract to
own its connection, sign-in, models, approvals, streaming updates and cancellation.
Optional `ui/3` contributions are available to runner adapters too. Return
`:pass` to retain the host behavior. Events include initialization, selection,
submission, picker contributions, messages, model metadata, activity and settings
labels; see `Alto.TUI.Backend` and the built-in implementations for return shapes.
Messages are offered to configured adapters, including inactive adapters with
running tasks. Protocol approval requests carry their own responder; the host
provides the shared approval controls.

Adapters are trusted host code with access to UI state. They must preserve their
protocol's approval and runtime controls. Native durable-input support is a
capability supplied by the adapter, not a special case for the `:alto` identifier.
Configure the Codex connection with options on its `tui_backends` entry.

## Subagent activity

**Ctrl+G, U** opens the current task's subagent list. Select a child to view its
model, parent ID, current stage, streamed activity, tool summaries and final result
in the context pane (a drawer on narrow terminals). **Esc** returns to context;
it does not stop the parent while inspecting a child. Repeated labels remain
separate because the list uses stable agent IDs. Approvals keep priority.
Live activity is bounded. Reopening a native task rebuilds child and grandchild
activity from durable session logs, including failed/cancelled children and
shared-session children. The inspector shows the saved session ID and completion
reason. Missing completion records are marked **no saved completion**, not assumed
running or successful. This read-only inspection also works behind a resume fence.
Discovery scans at most 4,096 session headers and retains 256 children; a notice
reports truncation or unreadable discovered sessions. Transient streaming fragments
that were never committed to history cannot be reconstructed.
