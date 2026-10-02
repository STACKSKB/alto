# Alto examples

## Agent configurations

These standalone files return ordinary Elixir keyword lists. Copy one and edit
its components; there is no preset registry or additional core dependency.

| Configuration | Intended use | Authority |
| --- | --- | --- |
| [`alto.example.minimal.exs`](../alto.example.minimal.exs) | Small coding agent: read, edit, write, direct commands | Interactive approval for edits and commands; commands use the host's permissions and network |
| [`alto.example.review.exs`](../alto.example.review.exs) | Repository review and investigation | Read, list, literal search and Git inspection; no writes, general commands or delegation |
| [`alto.example.workspace.exs`](../alto.example.workspace.exs) | Longer coding tasks with command output retention and handoff compaction | Approved edits and Bubblewrap commands; network disabled and `.git` protected |
| [`alto.example.team.exs`](../alto.example.team.exs) | Parallel investigation with a parent synthesizing findings | Read-only shared workspace; approved delegation, at most three children, two concurrent, one level deep |
| [`alto.example.assistant.exs`](../alto.example.assistant.exs) | Local notes, text research and document drafting | Approved edits; read/search and publication of existing files up to 256,000 bytes; no shell or delegation |

All five use an explicitly selected tool-capable Chat Completions model. They
start saved sessions and expose the same static provider catalog to the CLI and
TUI. They accept text inputs; change both the provider and model metadata when
enabling other modalities supported by your endpoint. They are workflow
examples, not compatibility layers for other agents.

From the repository root, build the CLI once, then run it **from the workspace
you want the agent to inspect**:

```sh
ALTO_CHECKOUT="$PWD"
(cd packages/alto_contrib && mix deps.get && mix escript.build)
export ALTO_MODEL="your-tool-capable-model-id"
export ALTO_API_KEY="your-provider-key"
# Optional; defaults to https://openrouter.ai/api/v1:
export ALTO_BASE_URL="https://your-endpoint.example/v1"

cd /path/to/your/workspace
"$ALTO_CHECKOUT/packages/alto_contrib/alto" \
  --config "$ALTO_CHECKOUT/alto.example.review.exs" \
  "Review the latest changes and cite actionable findings"
```

Replace the endpoint above with your service URL, or leave `ALTO_BASE_URL` unset
for OpenRouter. `OPENROUTER_API_KEY` is a fallback when `ALTO_API_KEY` is unset;
a local service that does not authenticate can omit both. An empty or missing
`ALTO_MODEL` produces a setup error. Loading a config does not contact the
provider, download skills, or start an agent. Unlike the default CLI onboarding,
these examples take credentials and the model from the environment.

For the optional TUI, select both the config and workspace explicitly:

```sh
cd "$ALTO_CHECKOUT/packages/alto_tui"
mix deps.get
mix alto.tui --config "$ALTO_CHECKOUT/alto.example.workspace.exs" \
  --project /path/to/your/workspace
```

The workspace profile requires Linux with `bwrap` and usable namespaces. Its
command sandbox has a minimal environment: expose required runtimes, caches and
environment variables through executor options when your project's tests need
them. It does not fall back to host execution. Retained command output is bounded
to eight files of at most 2 MB each under `.alto/command-output`; the command
still returns bounded output when this store is full. Read a returned retention
path with `read_file`, and remove old slot directories explicitly when no longer
needed. Add this output directory to the target project's ignore rules if desired.

The workspace, team and assistant examples cap context at 32,768 tokens with
4,096 reserved for output. Choose a model with at least that window or lower the
cap. Context estimates are conservative; compaction makes an additional model
request and needs saved history. The assistant uses the provider's text estimator
so published files count as references in model context; their full bytes still
count toward transcript limits. Runs have finite time, step, request and byte
limits. Child runs inherit limits individually; the team profile's 48-request
limit is **per run**, not a total billing cap across parent and children.

The CLI prints a session ID. Continue with the same config and
`--resume SESSION_ID "next task"`; `--no-session` disables persistence and makes
compaction unavailable. For embedding, load via `Alto.Contrib.Config.load/1`,
set `:cwd`, and call `Alto.Contrib.run/2` or `Alto.Contrib.resume/3`. A host without
terminal input should replace the interactive approval callback with its own
reviewer; closed input denies the invocation.

For optional skills, use the [upstream skill reuse example](upstream_skills/README.md).
It fetches explicitly selected, pinned upstream trees including supporting files
and licenses. These configs do not install a canonical Alto skill collection.

[`alto.agentic.exs`](../alto.agentic.exs) remains the larger coding-harness example
with optional external tools. The [configuration guide](../docs/configuration.md)
explains provider, tool, approval, executor and session composition.

## Embedded applications

The application examples show how to embed Alto in a host that owns admission,
storage, and external integration. Alto supplies the configured execution loop,
approvals, cancellation, and resource bounds.

- [Repository maintenance](repository_maintenance/README.md) receives signed
  reports, diagnoses a detached checkout, runs configured verification, and
  records a reviewed patch manifest before applying changes.
- [Document intake](document_intake/README.md) classifies and extracts real
  Markdown or text, keeps source identity and corrections, and publishes
  versioned JSON/CSV artifacts atomically.
- [Optional Oban host](oban_backend/README.md) shows durable admission and a
  worker that sends unknown external outcomes to explicit reconciliation.
- [Extension boundaries](../docs/extensions.md) shows host-side input
  transforms, provider-aware context estimates, hooks, trusted commands, and
  optional renderers and provider adapters.

The repository maintenance and document intake runners execute from
`packages/alto_contrib`; Oban declares contrib as a host dependency. Each example
has its own run instructions and integration checks.
