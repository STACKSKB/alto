# Delayed work

Alto.Queue supplies optional persisted due times; it does not choose application
priorities or start workers. Compose it with supervised Alto.Consumer processes
or another host using the claim/ack contract.

```elixir
Alto.Queue.admit(queue, "source:delivery-id", payload, delay_ms: 60_000)
Alto.Queue.put(queue, "job-key", payload, not_before_ms: unix_time_ms)
Alto.Queue.reschedule(queue, claim_id, 30_000)
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

Scheduled put/release records use log version 2; readers accept existing version
1 records. Old Alto versions reject version 2 rather than silently ignoring a
due time and executing work early. Do not downgrade a queue containing version
2 records without an explicit migration. Immediate-only logs remain version 1.

There are no background timers per record, automatic recurrences, new database,
or application-level task concepts. Consumer polling and configured capacity
remain the admission-to-execution mechanism.
