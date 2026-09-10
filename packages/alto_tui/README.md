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
