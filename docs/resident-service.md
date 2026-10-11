# Resident tasks and remote terminals

The optional `alto_contrib` resident host incorporates Zekkyou's implemented
service capabilities. Core Alto remains policy neutral. The host composes Alto's
runner, queue, consumers, operation ledger, checkpoints, aggregate child
continuations, durable budget accounts, sessions and Git workspace manager.
It adds bounded admission, delayed dispatch, explicit operator reconciliation,
exact parent recovery, independent child decisions and coordinated retirement.
The socket client and managed OpenSSH tunnel are `Alto.Contrib.Socket.Client`
and `Alto.Contrib.Socket.SSH`. Native terminal dependencies belong only to
`alto_tui`.

## Build and run

From an Alto source checkout with Elixir 1.18 and OTP 27 or later:

```sh
cd packages/alto_contrib
mix deps.get
mix escript.build
./alto --serve --config ../../examples/resident/alto.exs
```

The offline profile `local` lists files without a model account. In another
terminal, from the same package directory:

```sh
./alto resident schedule local '{"path":"."}' --id inspect
./alto resident tasks
./alto resident task inspect
./alto resident help
```

`mix alto.resident ...` offers the same operator commands. `start` remains a
direct resident run; `schedule` uses the bounded durable lifecycle, including
revision-fenced decisions and recovery. Client closure never owns run lifetime.
The default state path uses `$ALTO_STATE_HOME/alto/resident`, then
`$XDG_STATE_HOME/alto/resident`, otherwise
`~/.local/state/alto/resident`; set `ALTO_RESIDENT_STATE_DIR` in the example and
pass `--socket STATE/service.sock` on clients for a custom location. Direct
supervision uses `Resident.Service` with a validated `Resident.Config`.

A trusted `alto.exs` supplies `resident: [workspace: ..., state_dir: ...,
profiles: %{"name" => Alto.Config.default(...)}]`. Named profiles own provider,
prompts, tools, approvals and limits. Wire clients cannot supply execution
configuration. Scheduling caps profile limits. The inspect, approved-write,
team and coding-team examples show increasingly capable policies. Model examples
use `ALTO_RESIDENT_PROVIDER_URL`, `ALTO_RESIDENT_MODEL`, optional
`ALTO_RESIDENT_API_KEY`, and a configured worker model where needed; inspect
each example for its required environment. Keep secrets on the service host.

## Shared terminal UI

```sh
cd packages/alto_tui
mix deps.get
mix alto.tui --config ../../examples/resident/tui.exs
```

`Alto.TUI.Backends.Remote` uses the existing Alto renderer and menus. Its
background connection polls bounded server snapshots and reconnects with capped
backoff. The server owns workspace selection, durable task state, conversation,
approval authority and accounting. The local navigation catalog is never used
as a remote execution record. Queued tasks appear before execution. Follow-ups
use the saved server conversation and its original folder.

Use the shared workspace/task navigation, Enter to submit, Esc to request
cancellation, F8/F9 to approve/deny the viewed exact action, and Ctrl+C or
Ctrl+G then Q to detach. Ctrl+G then A opens operator controls for uncertain
outcomes, exact parent recovery, independently suspended child decisions and
terminal cleanup. Decisions carry the viewed revisions, generations, attempt
and suspension identities; stale clients cannot grant authority. The child
form accepts the exact identity displayed by `team-child-approval`.

The workspace menu opens/creates folders on the service host. Model/approval
policy changes require trusted server configuration. Native terminal selections
and preferences remain separate from server authority. Commands with uncertain
send outcomes are never retried automatically; reconnect and inspect before
resending. Remote local-file attachments are not yet uploaded; use files
already accessible to server tools. Remote Tab completion queries service-host folders asynchronously; it preserves
a pending Tab across the response and ignores stale replies. Effort choices
come from the service-owned model catalog.

For SSH, replace the socket option in the remote backend with
`ssh: "user@host", remote_socket: "/absolute/server/state/service.sock"`, and
optional `port: 22`. OpenSSH retains its configured authentication and host-key
checks. The tunnel owns a private local forwarding socket, bounded startup
errors and owner cleanup. Reconnection creates a new tunnel without restarting
server tasks. No remote host has been qualified in this migration; local tunnel
ownership tests use a controlled SSH fixture.

## Recovery and cleanup

Delayed and unstarted work returns after restart. Explicitly granted approvals
resume exact saved prepared values, with code/configuration checks and shared
budgets. Completed children are collected from retained continuations rather
than replayed. Independently suspended children each require their own exact
operator decision and admission grant. A workspace or saved transcript alone
never authorizes execution. Unknown dispatched work remains parked.

Use `task-reconcile ID committed|failed|retry --revision N --note EVIDENCE` only
after inspecting effects. Generic retry cannot bypass a retained parent
continuation. Use `task-recover` with the viewed task revision, parent key,
generation and continuation revision. `task-child-decide` also requires batch
revision, child attempt and suspension nonce. `task-cleanup` establishes
terminality and persists a restartable retirement plan before retiring parent
cells, child records and owned count accounts. Workspace patch export/discard
uses revision fences; reviewed application uses Alto's prepared manifest,
affected-file snapshots and immutable hashes, without changing the Git index.
Scoped mailbox identities derive from the execution tree, not caller-supplied
sender authority. Messages never create or wake agents. Queue compaction
preserves unread/claimed messages and the bounded deduplication window.

## Bundled native-free release

```sh
cd packages/alto_contrib
MIX_ENV=prod mix release alto
# Extract _build/prod/alto-0.0.2.tar.gz to the installation directory.
./_build/prod/rel/alto/deploy/alto-resident serve /absolute/path/alto.exs
```

The release bundles Erlang/Elixir, Contrib, examples and this guide; it contains
no `alto_tui`, `ex_ratatui` or terminal NIF. The `deploy/alto-resident` launcher
runs the same operator surface without system Mix, Elixir or Erlang. Linux
requires `flock`, and Git/OpenSSH when the configured policy uses them.

For a user systemd service, install the extracted release under
`~/.local/lib/alto`, copy `deploy/alto-resident.service` into
`~/.config/systemd/user`, and put trusted configuration in
`~/.config/alto/resident.exs`. Create `~/.config/alto/resident.env` containing
required profile environment and private credentials, mode 0600. Inspect the
unit paths, then run `systemctl --user daemon-reload` and
`systemctl --user enable --now alto-resident.service`. The unit restarts on
failure and kills the service process group on stop. No unit is installed or
enabled by building or testing this repository.

## Zekkyou saved-state boundary

This extraction reads the actual Zekkyou working tree, including its untracked
folder/catalog additions. Its dependency pin was `700ef245`; this branch starts
from Alto development commit `32c011b`. No persistent Zekkyou service state was
found in its checkout or the default user state path during the migration.
The `.work` directories are historical Alto source checkouts, not state stores.

Use a fresh Alto resident state directory. Do not copy or point Alto at a
Zekkyou state directory: retained binding kinds, policy/driver modules and code
hashes changed; the project catalog also uses Alto's current version 2 format.
Even a recent format-4 checkpoint is not proof of compatible authority. There
is no module aliasing, hash rewriting or automatic replay migration. Keep any
old state and its previous executable/configuration together; inspect, drain or
cancel pending work with that version after reviewing effects. Preserve unknown
effect evidence. Completed conversations can be retained as historical source;
resubmitting work requires a new task and explicit review. Alto retains its
existing checkpoint version fences for future same-service upgrades.

Memory, skills, Discord adapters, coordinated pausable child active-time budgets
and automatic uncertain-effect recovery remain outside this extraction.
