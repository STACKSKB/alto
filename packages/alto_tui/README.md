# Alto TUI

`alto_tui` is Alto's optional terminal UI example. It keeps the native ExRatatui
dependency outside the core production build while using the same host-owned
approval, execution, cancellation, session, and protocol boundaries.

From an Alto checkout, run the working example profile with:

```sh
cd packages/alto_tui
ALTO_TUI_LOCAL=1 mix deps.get
ALTO_TUI_LOCAL=1 mix alto.tui --config ../../alto.agentic.exs
```

The example hosts runs locally in its process tree. A separate application can
reuse the UI components and connect them to a persistent service through Alto's
transport APIs. The profile and maintained application examples are documented in
[`examples/README.md`](../../examples/README.md).

Press Enter to send a message. While a turn is running, Enter queues one follow-up
for that task; it starts after the current turn succeeds. A second follow-up
stays in the composer until the queued message has started. Queued messages are
kept in memory for the lifetime of the TUI.

The status bar shows whether Alto is waiting for the model, executing a tool, or
waiting for approval. Click the labeled Approve or Deny buttons, or press F8 or F9,
to answer a pending request. Esc stops the selected task's run and preserves your
draft. If a popup or the compact details
drawer is open, the first Esc closes it. Cancellation, failure, or a session-save
failure pauses the queued follow-up; press Enter with an empty composer to send it.

Provider and model forms show a cursor in the focused field. Type to edit, use
Left/Right to move the cursor, and Tab to move between fields. API keys stay masked.

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

Start a task in the current folder with **Ctrl+G, N** or **+ New task** above the
task list. **Ctrl+G, T** also includes a New task action.

Open a different folder through **Ctrl+G, W → Open another folder**. Enter an
existing folder path and press Enter (or click Open folder).
Relative paths start from the current workspace; `~` addresses your home folder.
Alto remembers the folder, selects it, and prepares a new task while preserving
your draft. Up/Down highlights folder suggestions; Tab completes the selected path
and lists its subfolders. Saved folders appear alongside directory matches.
The details pane shows the full working folder. Existing runs continue
in their original folders. Use Ctrl+G, W to switch between saved workspaces.

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
