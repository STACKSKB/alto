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
Pending messages appear below the current response and in the context pane.
When delivered, their queue notice disappears and each message becomes a separate
`you ›` turn before its response, including when native input continues the same run.

The status bar shows whether Alto is waiting for the model, executing a tool, or
waiting for approval. Click the labeled Approve or Deny buttons, or press F8 or F9,
to answer a pending request. Esc stops the selected task's run and preserves your
draft. If a popup or the compact details
drawer is open, the first Esc closes it. Cancellation, failure, or a session-save
failure pauses the queued follow-up; press Enter with an empty composer to send it.

Provider and model forms show a cursor in the focused field. Type to edit, use
Left/Right to move the cursor, and Tab to move between fields. API keys stay masked.

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
your draft. Tab extends the typed path to the longest common prefix of matching
folders, then lists the matching folders or subfolders. For example, `/hom` becomes
`/home/`, regardless of the current workspace. Up/Down followed by Tab accepts a
specific suggestion. Suggestions start unselected: Enter opens the typed path.
Down selects the first suggestion; Up selects the last. The hint changes when
Enter will open a selected suggestion. Typing or completing a path clears that
selection. Saved folders appear only while the input is empty.
The details pane shows the full working folder. Existing runs continue
in their original folders. Use Ctrl+G, W to switch between saved workspaces.

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
