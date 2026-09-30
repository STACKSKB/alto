# Multimodal input and output

`Alto.Content` can be passed as a user task, returned by a provider as a list of
blocks, or returned by a tool as the typed wrapper. Ordinary tool maps and lists
retain their JSON text behavior. Messages and sessions store validated blocks
with embedded bytes, so replay does not rely on the original upload path.

```elixir
{:ok, file} = Alto.Attachment.upload("report.pdf")
{:ok, block} = Alto.Attachment.content(file)
task = Alto.Content.new([Alto.Content.text("Summarize this report"), block])
Alto.run(task, provider: provider)
```

The CLI accepts `--attach FILE` repeatedly, including with `--resume`. Text
files become named text blocks; PNG/JPEG images become validated image blocks;
other bytes become named `file` blocks. Uploads snapshot the source into private
staging. `Alto.Attachment.update/2` changes a text attachment at its existing
path; `content/1` reads its current contents. `paste/2` splits UTF-8 text into
byte-bounded files, preferring line boundaries and preserving all bytes.

The TUI folds composer pastes at 4,096 bytes or 20 newline characters by
default, in 32 KB chunks. **F7** / **Ctrl+G, F** manages uploads, edits and
removal. **Ctrl+S** saves a text attachment in place; **Esc** cancels edits.
**Ctrl+V** reads PNG/JPEG images from local Wayland/X11 clipboards into the same
staging layer. Submission reads and freezes the edited files. Queued follow-ups
and steering keep the resulting blocks, rather than mutable file references.

For native HTTP providers, image input remains opt-in with `supports_images:
true`. Binary input is separately opt-in with `supports_files: true`.
OpenAI-compatible endpoints receive named base64 `file` parts; the endpoint
determines supported formats. Anthropic receives native PDF `document` blocks
and explicitly rejects other uploaded binary formats. Codex receives native
image/audio parts and private file paths for documents, which its own tools
can inspect subject to its sandbox. Arbitrary office-document extraction or
format conversion is not built into Alto.

The wire protocol accepts a validated block array in `start_run.task` and
`send_message.text`; plain string envelopes remain compatible. Programmatic
messaging uses `Alto.Messaging.send(input, text: "summary", content: blocks)`.
The text summary remains limited to 64 KB. Typed bytes count against mailbox
capacity, idempotency fingerprints and checkpoints; hosts may select up to
16 MB with `Alto.Input.open(max_bytes: 16_000_000)`. The connection's line limit
still applies to base64 uploads and output events (1 MiB by default).

## Generated files

`Alto.Content.file(name, media_type, base64)` means model-facing binary input.
`Alto.Content.artifact(name, media_type, base64)` means a downloadable output.
Artifact bytes stay in history, while provider requests receive a text
description of the file; providers do not need to interpret an opaque DOCX or
spreadsheet just to acknowledge its creation.

Enable `Alto.Tools.PublishFile` to expose an existing workspace file as an
output attachment. It reads a bounded, workspace-confined snapshot and returns
an artifact block. An agent creates images, documents, spreadsheets or other
files using its configured tools, then calls `publish_file` with the path.
The CLI and TUI save these files and show their paths, without displaying
base64. Typed assistant output works the same way, and saved TUI history can
recreate missing output files. Materialized outputs use a stable content digest
so repeated replay reuses the same path.

For direct image generation through OpenRouter, configure:

```elixir
[
  provider: {Alto.Providers.Images,
    model: image_model_id,
    api_key: api_key,
    options: %{"size" => "1024x1024", "output_format" => "png"}},
  tools: [],
  provider_timeout: 610_000,
  max_transcript_bytes: 16_000_000,
  max_event_bytes: 16_000_000
]
```

The adapter supports base64 output and reference images at `/images`, plus
optional `streaming: true`. Partial previews remain provisional; only completed
images become artifacts. The model must support the requested options.
OpenAI-compatible chat responses containing inline image/file parts or an
`images` array also become typed artifacts. Remote output URLs are rejected;
this decoding does not fetch provider-supplied URLs.

Staging files are private (`0600`, directories `0700`), bounded to 6 MB raw
bytes. Typed file/artifact blocks are capped at 8 MB base64. Host transcript,
event, HTTP-response and tool-result limits also apply. The coding profile
includes `publish_file` with an 8.1 MB tool-result allowance and 16 MB transcript
and event budgets. Other tool configurations must raise `max_tool_result_bytes`
above the default 64 KB when returning substantial binary artifacts. Staging
retention and deletion belong to the host, including abandoned draft files.

Provider formats follow the primary documentation for
[OpenRouter PDF input](https://openrouter.ai/docs/guides/overview/multimodal/pdfs),
[OpenRouter image generation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)
and [Anthropic PDF input](https://platform.claude.com/docs/en/build-with-claude/pdf-support).

## Model-facing tool images

Tools that need to return model-facing media use `Alto.Content`. This wrapper is
intentional: an ordinary map or list returned by a tool keeps the existing JSON
text behavior even if it happens to contain keys such as `type` or `data`.

```elixir
content =
  Alto.Content.new([
    Alto.Content.text("Screenshot after the change"),
    Alto.Content.image("image/png", base64_data, 1280, 720)
  ])
```

The runner calls `Alto.Content.normalize_tool_result/2` before adding typed
content to the transcript. The constructors return provider-neutral maps with
string keys; the wrapper, transcript, and session all use these same blocks.
`Alto.Content.decode_transcript/1` validates the blocks and wraps them for the
provider adapter. Provider-specific data URLs and Anthropic source maps are
created only when building a provider request.

`Alto.Tools.ReadImage` reads workspace-confined PNG and JPEG files. It reads no
more than the configured base64 limit permits, recognizes the format from file
bytes, validates PNG header integrity or JPEG frame dimensions, and rejects
images above the configured dimension or pixel limits. It returns an
`Alto.Content` image block with base64 data; it does not invoke a shell command
or require an image package.

```elixir
tools: [
  {Alto.Tools.ReadImage,
   max_encoded_bytes: 1_000_000,
   max_dimension: 8_192,
   max_pixels: 20_000_000}
]
```

The tool accepts optional `max_width` and `max_height` arguments. A requested
downsize fails with `:image_resize_unavailable` unless the tool is configured
with a `processor:` function taking `(bytes, media_type, width, height)` or an MFA
`{module, function, extra_arguments}` that returns `{:ok, encoded_bytes}`.
Processor output is sniffed and
checked against the byte, dimension, pixel, and requested-size limits before it
is returned.

Image delivery is opt-in at the provider as well. Configure
`supports_images: true` only for a model that accepts vision input. Both
`Alto.Providers.OpenAICompatible` and `Alto.Providers.Anthropic` expose the
result as `vision` in `describe/1` and reject image blocks before dispatch when
the option is false. OpenAI Chat Completions tool messages permit text only,
so that adapter keeps all correlated tool replies textual and appends one user
image message after the complete contiguous tool-reply group. Each base64 data
URL has its source tool call ID in an adjacent text part. Anthropic requests
receive native base64 image-source blocks inside the correlated tool result.

The default `max_tool_result_bytes` still applies to the native typed value.
Set that runner bound high enough for the configured encoded-image limit. The
reader supports only PNG and JPEG, and resizing needs an explicitly configured
backend.

The typed-content contract independently caps custom image blocks at 8 MB of
base64, 16,384 pixels per dimension, and 40 million pixels. It decodes the
bounded payload, sniffs its PNG/JPEG metadata, and requires the actual media
type and dimensions to equal the block's declared values. This also covers
typed image results produced by custom tools.
