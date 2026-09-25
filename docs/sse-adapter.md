# SSE parser selection

Both provider adapters use `Alto.Providers.SSE`, backed by
[`server_sent_events` 1.1](https://hexdocs.pm/server_sent_events/ServerSentEvents.html).
The library handles field interpretation, optional whitespace and multiline data.
It supports incremental parsing but does not impose Alto's byte limits, preserve
non-SSE JSON fallback, or flush incomplete events at EOF.

Original chunks go directly to the library, which owns parsing and split-CRLF
handling. Alto's separate counters enforce the per-event wire-byte limit without
rewriting chunks or buffering lines. `StreamEnvelope` bounds total response bytes,
including keepalives and comments, identically for both providers. EOF explicitly
flushes a final data frame; raw JSON fallback is byte-for-byte.

Compatibility tests exercise every two-chunk split of multibyte/CRLF input,
comments, multiline data, unfinished frames, raw bodies and per-frame limits.
Provider and streaming retry tests cover the shared HTTP integration.

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
