# SSE parser selection

Both provider adapters use `Alto.Contrib.Providers.SSE`, backed by
[`server_sent_events` 1.1](https://hexdocs.pm/server_sent_events/ServerSentEvents.html).
The library handles field interpretation, optional whitespace and multiline data.
It supports incremental parsing but does not impose Alto's byte limits, preserve
non-SSE JSON fallback, or flush incomplete events at EOF.

Original chunks go directly to the library, which owns parsing and split-CRLF
handling. Alto's separate counters enforce the per-event wire-byte limit without
rewriting chunks or buffering lines. `StreamEnvelope` bounds total response bytes,
including keepalives and comments, for both providers and model catalogs. The
same envelope handles HTTP errors, retaining at most a 64 KB prefix while
enforcing the total wire limit. Successful consumers receive only body chunks.
EOF explicitly flushes a final data frame; raw JSON fallback is byte-for-byte.

Compatibility tests exercise every two-chunk split of multibyte/CRLF input,
comments, multiline data, unfinished frames, raw bodies and per-frame limits.
Provider and streaming retry tests cover the shared HTTP integration.

## Stream budgets and partial responses

OpenAI-compatible and Anthropic transports default to `max_stream_bytes: 16_000_000`
for the entire wire response and `max_event_bytes: 1_000_000` for any one SSE frame
(or raw JSON response). Both include envelope overhead. A long reasoning/tool
response can exceed 2 MB even when each frame is small. Configure the cumulative
budget deliberately for the selected model and output reservation:

```elixir
{Alto.Contrib.Providers.OpenAICompatible,
 model: "configured-model",
 max_stream_bytes: 16_000_000,
 max_event_bytes: 1_000_000,
 timeout: 240_000,
 idle_timeout: 60_000}
```

The legacy `max_response_bytes` option remains a cumulative-stream alias. An
explicit `max_stream_bytes` takes precedence. Model catalogs keep their independent
8 MB `max_models_response_bytes` budget. No limit may be infinity. Raising the
wire budget does not raise transcript, retained-event, context or output-token
budgets; those limits remain independent.

An overflowing chunk is rejected before decoding or delivery. Earlier deltas may
already have been displayed; they are partial output, not a completed assistant
message. `%Alto.Provider.Failure{reason: reason, usage: usage, metadata: metadata,
diagnostics: diagnostics}` preserves accounting on direct adapter errors. The
runner keeps the original error reason and exposes bounded `provider_attempts`
in the result and persisted provider diagnostics. Diagnostics include received and
accepted wire bytes, parsed event count, content/reasoning byte counts when the
adapter supplies them, byte arrival and last SSE-event times relative to request
start, callback latency and configured limits. They do not retain partial response text. No retry
occurs after text or reasoning delivery. Unavailable usage remains `nil` in the
attempt evidence; aggregate zeroes cannot establish zero consumption.

Heartbeats update byte arrival without advancing the last completed SSE event.
HTTP failures carry the same wire counters even when usage is unavailable.
Attempt outcomes preserve bounded parsed `retry_after_ms` and `rate_limit_reset_ms`
hints; the separate `provider_retry` diagnostic records the policy's chosen delay.
Request headers and error-body text are excluded from these persisted diagnostics.

`finish_reason` and `terminal_status` describe provider termination. Reasoning-only
output fails separately with `:reasoning_only_model_response`; reasoning is saved
for inspection and is never automatically used as the final answer.

## Persistence-library assessment

SQLite remains a separate storage migration, not part of the parser replacement.
Exqlite could replace physical locking, atomic updates and crash recovery, but
Alto would still need its queue leases, revision fences, operation outcomes and
continuation identities. Alto is pre-release, so existing JSONL files need no
migration if a database backend replaces them.

[Exqlite's documentation](https://exqlite.hexdocs.pm/readme.html) describes native
calls on dirty NIF schedulers and precompiled artifacts or native builds. That
changes packaging relative to the current logs. [SQLite's WAL documentation](https://www.sqlite.org/wal.html)
describes reader/writer concurrency, single-writer constraints and checkpointing.
Those mechanisms are useful, but do not by themselves establish compatibility
with Alto's acknowledgement and recovery guarantees.

Decision for this refactor: retain the storage format and share its JSONL framing
and existing durable-write machinery. No Exqlite adapter has been implemented or
benchmarked. A later adapter evaluation should run the existing cross-VM and
crash tests against the candidate before a format or default changes.
