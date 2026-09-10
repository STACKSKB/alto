# Alto subagents

Subagents are requested by a trusted loop through an effect. A single child
uses `Alto.Effect.spawn_agent/1`; a bounded batch uses
`Alto.Effect.spawn_agents/1`:

```elixir
defmodule FanoutLoop do
  @behaviour Alto.Loop

  alias Alto.Effect
  alias Alto.Event
  alias Alto.Transition

  @impl true
  def init(%{jobs: jobs}, _spec) do
    agents = Enum.map(jobs, fn {id, task} -> %{id: id, task: task} end)
    Transition.continue(%{}, [Effect.spawn_agents(%{agents: agents})])
  end

  @impl true
  def handle_event(%Event{type: :subagents_completed, data: data}, state, _spec) do
    Transition.stop(state, data.results)
  end

  @impl true
  def handle_event(_event, state, _spec), do: Transition.continue(state)
end

Alto.run(%{jobs: [{"a", "first task"}, {"b", "second task"}]},
  loop: Alto.loop(FanoutLoop,
    subagents: Alto.Subagents.bounded(
      max_depth: 1,
      max_children: 8,
      max_concurrency: 3
    )
  ),
  provider: MyProvider)
```

`spawn_agents/1` accepts `%{agents: [...]}`. Each entry has the same spawn
fields as `spawn_agent/1`: required `:id` and `:task`, with optional provider,
loop, tools, model tools, maximum steps, and system prompt. IDs must be unique.
The batch preserves input order in `data.results`, even when children finish in
a different order. A completed child result has `id`, `status`, `output`, `error` when applicable,
`reason` for cancellation, `model_requests`, `usage`, `outcome`, `run_id`, and an optional `workspace` resource reference.
A child that could not start has only `id`, `status: :error`, and `error`. The single-child events are `:subagent_completed` or
`:subagent_failed`; a batch emits one `:subagents_completed` event containing
`%{results: results}`.

`Alto.Subagents.bounded/1` is Alto's policy constructor. `max_children` limits
one batch (default 16, range 1–64), while `max_concurrency` limits active children
in that batch (default 1, at most `max_children`). `max_depth` limits recursive
delegation; children cannot widen their inherited absolute depth allowance.
Batch concurrency is per loop, not a global service-wide limit. The entire
execution tree also remains subject to the root's shared budget.

The root run owns one shared effect counter, model-request counter, and
monotonic deadline. Children and batches consume those same counters and
deadline, so a batch cannot multiply the root allowance by its child count.
The child’s local `max_steps` remains an additional per-child limit.

Runtime tools are capabilities of the parent. An explicit child tool list must
be an exact normalized subset of the parent list; a module and `{Module, []}`
are equivalent. A child can narrow model exposure, but cannot add a tool or
replace a parent tool with another module under the same name. Approval and
tool bounds continue to be enforced by the host.

The parent owns each child handle, and a guardian monitors the parent process.
Explicit cancellation cancels all active children and allows one five-second
grace period for the whole batch before forced cleanup. Parent process death
also triggers cooperative cancellation through the guardians. Queued batch
entries are never started during cancellation. Child provider, tool, and loop failures become child
result data rather than crashing the parent. An uncertain child effect keeps
the parent result verdict at `:unknown`, even if the loop chooses an otherwise
successful output.

Children inherit transcript and tool-result bounds. The combined batch result
must also fit the parent's `max_tool_result_bytes` bound before delivery to the
loop; its serialized user-context message must fit the transcript bound. A
result-limit failure does not undo effects the children already performed. Aggregate descendant usage is merged into the root
`Result.usage`; `Result.model_requests` remains the root’s own model-step
count, while each child result reports its own model requests.

Delegated system prompts may be supplied with `system_prompt`, up to 64,000
bytes, and override the inherited system prompt for that child. The child task
does not get to alter runtime capabilities through prompt text. A trusted loop
may also add a bounded `context_message` to a model request; Alto records it as
a user message and validates it under the transcript limit.

Child runs share the parent session when one is configured, but a child is not
an independently durable job ledger entry. Session persistence is best effort
for the shared run and does not turn a child into a separately recoverable
queue job. Checkpoints are root-only: an independent child cannot suspend and
resume a shared parent checkpoint. Checkpoint fingerprints include the
subagent policy and tool configuration, so changing those trusted settings
invalidates an old packet.


## Execution-tree identity

Every serial tool context and result contains `agent_identity`, a map with
`root_run_id` and `path`. A root starts with its current run ID and an empty
path. Child paths append their spawn ID, so a grandchild can be addressed as
`["parser", "tests"]` within the same root. Spawn request data cannot replace
this identity. Internal host options are trusted configuration, not model input.
Identity paths are bounded to 64 nonempty UTF-8 segments of at most 256 bytes;
root IDs are nonempty UTF-8 strings of at most 256 bytes.

Exact checkpoint capture saves the identity and exposes a JSON summary in the
packet. Restore checks that summary against saved state and restores both the
result and live tool context identity. The resumed execution has a new current
run ID but keeps its original root namespace. A completed-session follow-up
starts a fresh namespace. Applications can use this to scope local mailboxes
without letting a model choose its sender identity. Identity does not itself
start a mailbox, authorize a recipient, persist child execution or isolate a
workspace; these remain separate policies and mechanisms.

`Alto.Queue.claim_matching/5` provides an optional generic storage primitive
for addressed consumers. A bounded exact map selector filters payload fields
inside the atomic claim operation, before applying existing due-time, FIFO,
wire-byte and lease rules. Unrelated records are not claimed. The queue remains
one bounded store; applications define envelopes, addresses and authorization.


## Isolated coding workspaces

A host can opt a bounded subagent policy into independent Git checkouts:

```elixir
{:ok, ledger} = Alto.OperationLog.start_link(
  id: "workspaces", name: nil, dir: "/private/alto-state/operations", max_ops: 128)
manager = Alto.Workspaces.new(
  root: "/private/alto-state/workspaces", ledger: ledger)
policy = Alto.Subagents.bounded(
  max_depth: 1, max_children: 4, max_concurrency: 2, workspaces: manager)
# Use policy as the parent loop's :subagents option.
```

The host captures one clean source commit before admitting the batch. Each
execution-tree child identity gets its own local clone, object store and index.
The runner sets the child's tool cwd; a spawn request cannot choose another
cwd. Descendants inherit the manager along with existing authority and budgets.
Use a unique child ID for each assignment within a root execution: an already
used workspace is retained for review and cannot execute that assignment again.

The built-in Git backend requires an ordinary repository with a `.git`
directory and a clean source checkout. Dirty sources, linked source worktrees,
submodules, source-local filters, alternates and symlinked paths are rejected
explicitly. Ignored build output is neither cloned nor captured; it does not consume checkout bounds.
Source bytes, file counts, checkout bytes, patch bytes and command time are
bounded. Host-global Git configuration and inherited Git environment are
excluded; hooks and external diff commands are disabled.

Git metadata lives beside the checkout, outside the directory exposed to file
tools. A frozen patch also lives outside that directory and is checked against
its recorded hash whenever read. These are separate writable workspaces, not
an operating-system security sandbox: unrestricted commands and custom tools
retain their configured authority. Use an appropriate command executor when
process-level filesystem or network isolation is required.

Creation, worker use and patch capture are resource operations in the existing
`Alto.OperationLog`. Dispatch is recorded before mutation. Ready, worked and
frozen resources are nonterminal checkpoints and cannot be evicted to make room
for another workspace. A process crash leaves its unfinished operation visible;
Alto does not repeat it automatically. A grant interrupted before dispatch is
also retained for review. Cooperative child cancellation releases its lock
once the runner has stopped, while uncertain workspace failures propagate an
unknown verdict to the parent.

Completed child results contain a `workspace` map with its ID, revision,
status and metadata, including the source commit and frozen patch hash.
`Alto.Workspaces.get/2` inspects it; `patch/2` returns the bounded immutable Git
diff. Hosts can also use `prepare/2`, `create/3`, `use/4` and `freeze/3` directly
with an optional backend implementing `snapshot/2`, `checkout/3` and `diff/3`.
A backend must return bounded JSON snapshot metadata and cannot supply runtime
credentials in that metadata.

`discard/4` requires the viewed revision and an explanatory note. It holds the
same operating-system resource lock as worker use, so cleanup cannot remove a
live worker's files. Interrupted resources remain cleanup obligations until
explicitly discarded. Workspace storage survives ledger restart; it does not
make the child run independently resumable. Applying a patch to the lead's
checkout remains a separate reviewed integration operation; capture never
modifies the source checkout.
