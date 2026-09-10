# Document intake

This profile accepts real Markdown or plain text. It derives a stable identity from normalized source bytes, extracts headings and `key: value` list fields deterministically, asks a configured Alto provider only when title or summary is ambiguous, validates the resulting schema, and publishes versioned JSON and CSV bundles atomically. A human correction is a map passed to `DocumentIntake.correct/2`; identity is immutable so corrections cannot fork the dedup key.

Run the deterministic path with:

```sh
mix run examples/document_intake/run.exs input.md artifacts/
```

Ambiguous input can be corrected at the command line:

```sh
mix run examples/document_intake/run.exs input.md artifacts/ \
  --title "Document 42" --summary "Project memo" --field project=Alto
```

Applications can supply `provider: {Provider, options}` (or `config: %Alto.Config{}`) for the default `Alto.run/2` extraction path. The injected `llm: {ResolverModule, options}` and one argument resolver function remain available for tests and custom integrations. Candidate state can be persisted with `state_dir: artifacts/` and loaded after a restart with `load_candidate/2`. Re-running identical input returns its existing artifact; explicit corrections create a new version with provenance.

The CLI accepts a trusted Alto configuration file with `--config CONFIG.exs`; it is evaluated with `Alto.Config.load/1`. For unattended runs, the configuration supplies the provider and its provider options. A persisted candidate remains available if provider extraction fails, and `reconcile/3` applies an operator correction after restart.
