# Delayed work

Alto.Queue supplies optional persisted due times; it does not choose application
priorities or start workers. Compose it with supervised Alto.Consumer processes
or another host using the claim/ack contract.

```elixir
Alto.Queue.admit(queue, "source:delivery-id", payload, delay_ms: 60_000)
Alto.Queue.put(queue, "job-key", payload, not_before_ms: unix_time_ms)
Alto.Queue.release(queue, claim_id, delay_ms: 30_000)
```

Claims, including byte-bounded claims used by Consumer, skip pending records
whose due time has not arrived. Eligible records retain FIFO order. Existing
calls without scheduling options remain immediately eligible. Admission keeps
the first payload and schedule; business-key updates explicitly replace both.

`release(queue, claim_id, delay_ms: delay)` persists a new due time under the
current lease fence. An expired or replaced owner cannot reschedule a newer
claim. This API does not establish retry safety: the host must still respect
OperationLog outcomes and never repeat an uncertain effect automatically.

Due times are absolute Unix milliseconds on disk. The default clock uses system
time; after downtime, overdue work becomes eligible on the next claim. Clock
adjustments can advance or postpone eligibility. `clock: zero_arity_function`
is an optional trusted queue setting for deterministic tests; it must return
Unix milliseconds and is also used for leases.

Queue logs use one current format for immediate, scheduled, and retained state.
Unsupported historical formats are rejected.

There are no background timers per record, automatic recurrences, new database,
or application-level task concepts. Consumer polling and configured capacity
remain the admission-to-execution mechanism.


## Retained queue state

Queues keep append-only history by default. Hosts that need bounded retained
state rather than historical audit entries can set `auto_compact: true` or call
`Alto.Queue.compact/1` explicitly. Automatic compaction runs before a new append
would exceed `max_log_bytes`. It retains every pending and claimed record in
FIFO order, portable term payloads, revisions, generation/operation identities, delayed
due times and active claim IDs/owners/lease deadlines. It does not reclaim
leases, acknowledge unread work or cancel records as a cleanup policy.

The newest `max_completed` deduplication keys retain their ordering across
compaction and restart. Older keys remain expired under the existing bounded
window: their old log entries are removed, and a later delivery may be admitted
again. There is no new time-based message expiry. If the retained state plus the
requested append cannot fit the log bound, the mutation fails explicitly;
compaction never drops live work or shrinks the configured dedup window to fit.

Replacement uses a file-and-directory-synced atomic rename while holding the
queue's lifetime lock. Each log starts with one complete snapshot containing its
next numeric record ID, live records, and completed delivery identities. Subsequent
lines encode native queue mutations. An incomplete snapshot fails closed; only
later torn appends receive normal tail repair. This is the current prerelease
format; older queue logs are not migrated. Payloads and claim owners must be
portable data; process IDs, references, ports, and functions are rejected.
`compact/1` reports byte counts and retained live/completed counts. This is a
queue-state maintenance operation, not an audit-log export.
