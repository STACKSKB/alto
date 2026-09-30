# Alto contrib

Optional applications and integrations built on the Alto runtime. This package
depends on `alto`; the runtime does not depend on this package.

Run the command-line application from this directory:

```sh
mix deps.get
mix alto --config ../../alto.agentic.exs "Explain this repository"
```

`mix escript.build` creates the `alto` executable. Terminal interaction is provided
by the separate `alto_tui` package.
