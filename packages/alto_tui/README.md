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

Drag with the left mouse button to select visible text anywhere: conversations,
workspaces, details, settings, the composer, borders, and popups. Click actions
happen on release, so selecting a button's label does not activate it. Pane seams
still resize; use Alt+drag to select across a seam. Scroll to older content before
selecting it. Selection freezes the displayed screen while background work continues.

Press Ctrl+C (or Alt+C) to copy the selection; Ctrl+C without a selection retains
its cancel/quit behavior. Ctrl+Shift+A selects the entire visible screen when your
terminal forwards that chord. Esc clears selection first. Copy uses the terminal's
OSC 52 clipboard support, including over SSH and through tmux; your terminal must
allow clipboard writes. Shift+drag and the terminal's own copy shortcut remain a
fallback on terminals that reserve Shift for native selection.

Paste with your terminal's usual shortcut (often Ctrl+Shift+V or Cmd+V). Bracketed
paste inserts text without submitting it, including multiline text and form fields.
Ctrl+V also reads the local clipboard using `wl-paste`, `xclip`, `xsel`, or `pbpaste`
when available; otherwise it inserts the last selection copied in this TUI.

Open a different folder with **F7** or click **＋ New workspace** at the top of
Workspaces. Enter an existing folder path and press Enter (or click Open workspace).
Relative paths start from the current workspace; `~` addresses your home folder.
Alto remembers the folder, selects it, and prepares a new task while preserving
your draft. Up/Down recalls saved folders in the dialog. The details pane shows the full working folder. Existing runs continue
in their original folders. Use Ctrl+G, W to switch between saved workspaces.
