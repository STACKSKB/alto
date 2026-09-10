# Optional Oban inbox example

This is a separate host application, not an Alto dependency. It owns Ecto,
PostgreSQL, Oban, their supervision, and their migrations. Alto only calls the
configured `Alto.Inbox` adapter.

## Run it

With PostgreSQL available, from this directory:

```sh
export DATABASE_URL=ecto://postgres:postgres@localhost/alto_oban_example_dev
export WEBHOOK_SECRET=replace-me
mix deps.get
mix ecto.create
mix ecto.migrate
mix run --no-halt -e 'Alto.CLI.main(["--serve", "--config", "alto.exs"])'
```

The `mix run` form matters for a host application: it starts the host's Repo
and Oban supervision tree before entering Alto's server. Send a signed POST to
`http://127.0.0.1:4748/hooks/events`; the listener commits an inbox identity and
an Oban job in one database transaction before returning `200`.

For example, send one signed delivery from another shell:

```sh
body='{"value":42}'
signature=$(printf %s "$body" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -binary | openssl base64 -A)
curl --fail-with-body http://127.0.0.1:4748/hooks/events \
  -H "X-Signature: $signature" \
  -H "X-Delivery-ID: delivery-42" \
  -H "Content-Type: application/json" \
  --data "$body"
```

## Test it

The default checks don't need a database and verify compilation, adapter option
validation, `alto.exs` selection, and worker execution:

```sh
mix test --no-start
```

After creating and migrating the configured database, exercise the actual
transaction and duplicate constraint with:

```sh
mix test --include database
```

To use the shallow path instead, replace the endpoint's `on_event` value with:

```elixir
{:start_run, "event_flow"}
```

That path doesn't start or require this example's database stack in a normal
Alto deployment.

## Why there is a separate inbox table

Oban uniqueness is an insertion-time facility, and `period: :infinity` lasts
only while the matching job remains retained. The `alto_inbox_deliveries`
primary key makes source delivery identity independent of Oban pruning. Its row
and the job are inserted atomically with `Ecto.Multi`, so a successful webhook
cannot commit one without the other.

The table stores hashes and the source key, while the actual body lives in the
Oban job args. Production deployments should add an explicit retention policy
for delivery rows that is at least as long as the sender's redelivery window.

## Deliberate host responsibilities

- Oban queue concurrency controls execution, not admission volume. If the host
  needs a hard pending-job cap, enforce it transactionally in this adapter and
  return `{:error, :full}`.
- `period: :infinity` alone is not permanent deduplication: it ends when Oban
  prunes the matching job. The separate delivery table is authoritative.
- The worker decides which Alto run options correspond to the persisted
  `"run"` name. No executable configuration or module name comes from the
  webhook body. A host that must preserve historical behavior should persist a
  configuration or deployment version with the name and reject jobs it can no
  longer resolve.
- Alto bounds the HTTP body before calling the adapter. The adapter is still
  responsible for database timeouts, pool sizing, retention, retry policy, and
  operational monitoring.
- An Oban job retry reruns the entire Alto workflow. Automatic retries are only
  safe when all effects are idempotent or the worker can classify the outcome
  as definitely retryable. Ambiguous external effects should be discarded or
  parked for operator review; Oban's at-least-once execution does not make
  remote effects exactly-once.
