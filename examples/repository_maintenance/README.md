# Repository maintenance

This profile turns a signed CI or local failure report into durable, source scoped work. The report is admitted with `source:delivery_id`, claimed once, validated, and checked out at its exact commit in a temporary Git worktree. A configured OpenAI compatible provider may inspect and edit that isolated checkout with bounded Alto file tools. The profile runs a configured test argv and `git diff --check`, then writes separate patch, test-output, and manifest artifacts outside the checkout. The queue claim remains held on failure for lease based recovery.

Run it with:

```sh
ALTO_PROVIDER_ENDPOINT=https://api.example/v1/chat/completions \
ALTO_MODEL=your-model ALTO_API_KEY=... \
mix run examples/repository_maintenance/run.exs /path/to/repo failure.json
```

The provider settings are required for diagnosis, and the checkout must support the configured test command (the runner defaults to `mix test`; call `Workflow.process/3` with `tests: ["npm", "test"]` or another argv). Admission and validation remain deterministic and useful without credentials; the workflow stops with `:provider_required_for_maintenance` before pretending a repair succeeded. For signed HTTP reports, configure the root `Alto.Listeners.Webhook` with `Alto.Ingress.HMAC`, `Alto.Ingress.IdentityHeader`, and `on_event: {:enqueue, {RepositoryMaintenance.WebhookInbox, queue: queue, source: "github"}}`; this adapter decodes the body and uses the same `Workflow.admit/2` path as the CLI. Applying is a separate reviewed operation: inspect the manifest and patch, set `reviewed` to `true`, recompute the manifest SHA-256, then run `mix run examples/repository_maintenance/run.exs apply REPO MANIFEST MANIFEST_SHA256`; the base commit, clean tree, and patch hash are rechecked immediately before `git apply`.
