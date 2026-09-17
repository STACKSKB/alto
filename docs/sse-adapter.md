# SSE parser selection

Both provider adapters use `Alto.Providers.SSE`, backed by
[`server_sent_events` 1.1](https://hexdocs.pm/server_sent_events/ServerSentEvents.html).
The library handles field interpretation, optional whitespace and multiline data.
It supports incremental parsing but does not impose Alto's byte limits, preserve
non-SSE JSON fallback, or flush incomplete events at EOF.

The shared envelope therefore accounts original wire bytes before passing complete,
normalized lines to the library. This also preserves Alto's delayed handling of
split CRLF. EOF explicitly flushes a final data frame; raw fallback is byte-for-byte.
Provider-specific JSON interpretation and stream lifecycle stay in their adapters.

Compatibility tests exercise every two-chunk split of multibyte/CRLF input,
comments, multiline data, unfinished frames, raw bodies and per-frame limits.
Existing provider and streaming retry tests cover the HTTP integration.
