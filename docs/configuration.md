# Configuring Alto

Alto takes an ordinary Elixir keyword list for each run. An `alto.exs` is a
trusted Elixir program that returns that list. It can call functions, import
shared configuration, read environment variables, and construct custom modules
or callbacks. Keep as many config files as your workflows need; the filename is
a convention, and `--config` accepts any path.

CLI commands below run from `packages/alto_contrib`; TUI commands run from
`packages/alto_tui`. File loading and host defaults belong to contrib. Library
hosts opt in with `Alto.Contrib.configure/1` or use `Alto.Contrib.run/2`. Direct
core runs accept explicit policies; they do not discover project files, select
a reducer, or infer a provider retry policy.

## Defaults and config selection

`Alto.default_config()` returns the library defaults. Use `Keyword.merge/2` or
`Alto.default_config(overrides)` to change them. Nested values are replaced;
there is no implicit deep merge.

Library defaults include an empty tool list, a deny policy for approvals, serial
tool execution, and bounded execution. Providers and credentials are supplied
by the caller. The CLI adds read-only file tools, the coding prompt, project
instructions, interactive approvals, and session persistence when those entries
are omitted. If you pass a complete default config, its explicit entries take
precedence over those CLI additions.

The CLI selects configuration in this order:

1. `--config FILE`.
2. The `ALTO_CONFIG` environment variable.
3. `$XDG_CONFIG_HOME/alto/config.exs`, or `~/.config/alto/config.exs`.
4. CLI defaults when none of the above exists.

`--no-config` skips the environment and per-user config. It cannot be combined
with `--config`. Alto does not automatically execute a workspace's `alto.exs`.
The TUI uses its `--config` argument, defaulting to `alto.agentic.exs` relative
to its working directory; pass an explicit path when running from another folder.

## A small profile

Save this as `alto.exs` for read-only model-assisted work:

```elixir
Alto.default_config()
|> Keyword.merge(
  tools: [Alto.Contrib.Tools.ListFiles, Alto.Contrib.Tools.ReadFile, Alto.Contrib.Tools.SearchFiles],
  prompt: &Alto.Contrib.Prompts.Coding.build/1,
  project_instructions: :auto,
  max_steps: 48,
  run_timeout: 30 * 60 * 1_000
)
```

```sh
mix alto --config alto.exs "Explain this repository"
```

With no `provider` entry, the CLI resolves OpenRouter from `ALTO_API_KEY`,
`OPENROUTER_API_KEY`, or the private credential store created by
`mix alto --setup`. `ALTO_MODEL` overrides that store's default model.
An explicit `provider` is used as supplied, including its credentials and model;
set `provider: nil` for a providerless rule loop.

## Multiple models and sessions

For example, keep shared settings beside several workflow profiles:

```text
profiles/
  base.exs
  review/alto.exs
  chat/alto.exs
  local/alto.exs
```

`profiles/base.exs` can contain the small profile above. Each child evaluates it
relative to its own file, then overrides the values it needs.

`profiles/review/alto.exs` selects a model and credentials explicitly:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  provider:
    {Alto.Contrib.Providers.OpenAICompatible,
     base_url: "https://openrouter.ai/api/v1",
     api_key: System.fetch_env!("OPENROUTER_API_KEY"),
     model: System.fetch_env!("ALTO_REVIEW_MODEL")}
)
```

`profiles/chat/alto.exs` removes tools and uses a conversational prompt:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  loop: Alto.chat_loop(),
  tools: [],
  prompt: &Alto.Contrib.Prompts.Chat.build/1,
  project_instructions: nil
)
```

`profiles/local/alto.exs` points at a local OpenAI-compatible server:

```elixir
{base, _binding} = Code.eval_file(Path.expand("../base.exs", __DIR__))

Keyword.merge(base,
  provider:
    {Alto.Contrib.Providers.OpenAICompatible,
     base_url: "http://localhost:1234/v1",
     model: System.fetch_env!("ALTO_LOCAL_MODEL")}
)
```

Select one for each run, or set a default for the current shell:

```sh
mix alto --config profiles/review/alto.exs "Review this change"
mix alto --config profiles/chat/alto.exs "Help me think through the design"
export ALTO_CONFIG=/absolute/path/to/profiles/local/alto.exs
mix alto "Explain the parser"
```

One-shot CLI runs save sessions and print their IDs. List them with
`mix alto --sessions`, and select the desired config for each follow-up:

```sh
mix alto --resume SESSION_ID --config profiles/review/alto.exs "Check error handling too"
```

A resumed run resolves its provider, tools, approvals, and limits from the
selected config. Its system prompt comes from saved history; changing `prompt`
or project instruction files does not replace that history. Config files are
not embedded in sessions. Use `--no-session` for a one-shot run without
persistence. See [conversation revisions](conversations.md) for recovery and
branching.

To use a profile with `mix alto.tui --config FILE`, include a native backend in
its keyword list, for example:

```elixir
Keyword.put(base, :tui_backends, [alto: {Alto.TUI.Backends.Native, []}])
```

For several selectable providers in one TUI, configure `provider_profiles`;
its provider and model pickers remember choices across tasks. See the
[TUI guide](../packages/alto_tui/README.md#providers-and-backends).

## Attachments and model inputs

The CLI accepts repeated `--attach FILE` arguments on new and resumed sessions:

```sh
mix alto --config profiles/review/alto.exs --attach report.pdf "Summarize this report"
```

Text files become named text blocks; PNG/JPEG images become validated image
blocks; other files become named binary blocks. Uploads snapshot local files
into private staging. Submitted bytes are embedded in history, so replay does
not depend on the original path. See the [TUI guide](../packages/alto_tui/README.md#attachments-and-pastes)
for uploads, editable large pastes and clipboard images.

Declare inputs for the actual configured model with provider options such as
`input_modalities: ["text", "image", "audio", "file"]`. Legacy `supports_images:
true` and `supports_files: true` declare image/file support for one configured
model. Catalog metadata takes precedence when selecting models, including
OpenRouter architecture metadata and Codex `inputModalities`. For catalogs without
metadata, use `model_input_modalities: %{"model-id" => ["text", "image"]}`.
Unsupported or unknown media fails before dispatch. Switching or delegating to
another model clears stale capabilities; queued, historical and tool media is
checked too. Audio/video files cannot bypass checks through generic file support.

| Provider | Input transport |
| --- | --- |
| OpenAI-compatible | Named base64 file parts; supported MP3/WAV becomes native `input_audio`; other audio formats and video transport are rejected |
| Anthropic | Native PNG/JPEG image blocks and PDF documents; other uploaded binary formats are rejected |
| Codex | Native image/audio parts and private document paths, inspected by its tools subject to its sandbox |

The endpoint and selected model determine supported file formats. Alto does not
extract arbitrary office-document text or convert files automatically.

## Generated files and images

The coding profile includes `Alto.Contrib.Tools.PublishFile`: an agent creates a file
with its configured tools, then calls `publish_file` with the workspace path.
The tool returns a bounded snapshot as an output attachment. The CLI and TUI save
artifacts privately and show their paths. Provider requests receive a text
description of output artifacts, while their bytes remain in history.
See [typed content](extensions.md#typed-content) for custom tools and hosts.

For direct image generation through OpenRouter, configure an image model:

```elixir
[
  provider: {Alto.Contrib.Providers.Images,
    model: image_model_id,
    api_key: api_key,
    input_modalities: ["text", "image"],
    options: %{"size" => "1024x1024", "output_format" => "png"}},
  tools: [],
  provider_timeout: 610_000,
  max_transcript_bytes: 16_000_000,
  max_event_bytes: 16_000_000
]
```

The adapter supports base64 output and reference images at `/images`, with
optional `streaming: true`. Partial previews remain provisional; only completed
images become artifacts. The model must support the requested options.
OpenAI-compatible chat responses containing inline image/file parts or an
`images` array also become artifacts. Remote output URLs are rejected rather
than downloaded.

Staging files are private (`0600`, directories `0700`) and bounded to 6 MB raw
bytes. Typed file/artifact blocks are capped at 8 MB base64. Other host transcript,
event, HTTP-response and tool-result limits still apply. The coding profile uses
an 8.1 MB tool-result allowance and 16 MB transcript/event budgets. Other profiles
must raise the default 64 KB tool-result limit for substantial binary artifacts.
Staging-file retention and deletion belong to the host.

Provider format references: [OpenRouter PDFs](https://openrouter.ai/docs/guides/overview/multimodal/pdfs),
[OpenRouter image generation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)
and [Anthropic PDFs](https://platform.claude.com/docs/en/build-with-claude/pdf-support).

## Coding tools and execution policy

The supplied [`alto.agentic.exs`](../alto.agentic.exs) is a complete coding
profile. It adds edits, approved Git mutations, sandboxed shell/argv execution,
parallel reads, context reduction, and agent tools. Use it directly or evaluate
it as a base for your own profile:

```elixir
{coding, _binding} = Code.eval_file("/absolute/path/to/alto/alto.agentic.exs")
Keyword.merge(coding, max_steps: 64, run_timeout: 60 * 60 * 1_000)
```

Tools, permissions, and sandbox mounts are explicit configuration. The supplied
profile protects `.git` from ordinary file edits and commands, and gives Git
mutation its own approved tool. Bubblewrap commands have a writable workspace,
a read-only runtime, a fresh temporary directory, and network disabled by
default. Executor `network: :inherit` enables network access;
`Alto.Contrib.Command.Executors.Unsandboxed` selects host execution.

Set `approval: &Alto.Contrib.Approval.interactive/2` for terminal decisions or
`approval: :approve` for an explicitly trusted unattended workflow. Custom
callbacks can make policy decisions from the prepared request. See
[extensions](extensions.md#approval-decisions) for those contracts.

## Prompts, context, and limits

`prompt` accepts a builder or text; `prompt: nil` omits the configured system prompt.
With `project_instructions: :auto`, a fresh CLI or TUI task loads the first
existing root instruction file, `alto.md` then `AGENTS.md`, up to 32,000 bytes.
Nested instructions are read by the agent rather than automatically injected.
Use `project_instructions: nil` to disable this input.

`loop` selects the control policy. `Alto.default_loop/1` supports tool batches,
context admission, middleware, and subagents. `Alto.chat_loop/1` disables tool
execution; `Alto.rule_loop/1` runs deterministic tool steps; `Alto.loop/2` accepts
a custom loop. Context reduction is opt-in and configured separately through
`compaction`. See [loops](loop-contract.md), [tool batches](tool-batches.md),
[context reduction](context-reduction.md), and [subagents](subagents.md).

| Setting | Scope |
| --- | --- |
| `run_timeout` | Whole execution tree, including descendants |
| `max_steps` | Model steps in a run; positive integer or `:infinity` |
| `max_model_requests` | Shared model-request budget; positive integer or `:infinity` |
| `max_effects` | Shared effect budget across the execution tree |
| `provider_timeout` | Each supervised provider call |
| `tool_timeout` | Each supervised tool call |
| `approval_timeout` | Waiting for an approval decision |
| `max_tool_result_bytes` | Retained tool result size |
| `max_transcript_bytes` | Model transcript size |
| `max_events`, `max_event_bytes` | In-memory event retention |
| `conversation_retained_turns` | Rewind/fork history; all turns by default, or the latest N turns |
| `max_conversation_bytes` | Distinct stored conversation objects and manifests, or `:infinity` |

Timeouts are milliseconds. HTTP providers also accept `timeout` for a total
request deadline and `idle_timeout` for stream silence. Set `provider_timeout`
above the HTTP deadline if the transport should report its own timeout first.
HTTP streaming also has independent provider options `max_stream_bytes` (16 MB
cumulative wire budget) and `max_event_bytes` (1 MB per frame). These differ from
the runner retained-event limit of the same name. See [stream budgets](sse-adapter.md#stream-budgets-and-partial-responses).
Config changes apply when a run starts or resumes.

The library defaults to 32 model steps, 256 shared model requests, and a 128 MB
conversation storage budget. The supplied coding profile selects `:infinity` for
those three limits to support long tasks. All turns are retained incrementally by
default; `conversation_retained_turns: N` limits rewind/fork history while keeping
the entire current context. Run deadlines, effect budgets and cancellation still
apply. See [conversation revisions](conversations.md) for storage and migration.

`provider_retries` bounds retries before any model output is delivered; it is
zero by default. The transient policy honors provider retry hints, keeps waiting
cancellable, and stops rather than waiting through a delay longer than 60 seconds.
An attempt that has already streamed output is not automatically replayed.

## Library and resident hosts

Library calls take the same keyword list, with a provider supplied by the host:

```elixir
{:ok, options} = Alto.Contrib.Config.load("profiles/review/alto.exs")
result = Alto.Contrib.run("Review the parser", options)
```

`mix alto --serve --config FILE` exposes the selected config as `"default"`.
Add `runs` for named overrides and `sessions: true` to persist served runs:

```elixir
Keyword.merge(base,
  sessions: true,
  runs: %{
    "review" => [max_steps: 48],
    "chat" => [loop: Alto.chat_loop(), tools: [], prompt: &Alto.Contrib.Prompts.Chat.build/1]
  }
)
```

Here `base` is the previously constructed keyword list. A client selects a
configured name in `start_run`; it cannot submit executable Elixir or arbitrary
run overrides. Each named list is merged into the base options. See the
[front-end protocol](../PROTOCOL.md) and [execution hosts](runners.md).
