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
