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

This is a compatibility adapter, not a complete replacement of Alto's framing
code. The library owns field interpretation; the envelope still scans lines to
bound original wire bytes before buffering and to retain raw-response behavior.
The initial adoption removed 142 physical lines including tests and documentation.

## Persistence-library assessment

SQLite remains a separate storage migration, not part of the parser replacement.
Exqlite could replace physical locking, atomic updates and crash recovery, but
Alto would still need its queue leases, revision fences, operation outcomes and
continuation identities. Existing JSONL readers and retained logs would require
an explicit migration and export contract before selecting a database backend.

[Exqlite's documentation](https://exqlite.hexdocs.pm/readme.html) describes native
calls on dirty NIF schedulers and precompiled artifacts or native builds. That
changes packaging relative to the current logs. [SQLite's WAL documentation](https://www.sqlite.org/wal.html)
describes reader/writer concurrency, single-writer constraints and checkpointing.
Those mechanisms are useful, but do not by themselves establish compatibility
with Alto's acknowledgement and recovery guarantees.

Decision for this refactor: retain the storage format and share its JSONL framing
and existing durable-write machinery. No Exqlite adapter has been implemented or
benchmarked, and no storage migration is claimed. A later adapter evaluation
should run the existing cross-VM and crash tests against both backends before a
format or default changes.
