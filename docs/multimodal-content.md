# Multimodal tool content

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
content to the transcript. The normalized form is a provider-neutral list of
JSON objects. Sessions therefore persist the same blocks they send on a later
turn, without persisting provider-specific data URLs or Anthropic source maps.
`Alto.Content.decode_transcript/1` validates and rehydrates these blocks at a
provider boundary.

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
with an `Alto.Image.Processor` implementation. Processor output is sniffed and
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
