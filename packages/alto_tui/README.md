# Alto TUI

Alto's optional terminal interface provides streaming conversations, model and
provider selection, approvals, saved tasks, workspaces, search, and subagent
inspection. It runs local Alto workflows and supports configurable backends,
including Codex. The native ExRatatui dependency stays in this package.

## Run it

From an Alto checkout:

```sh
cd packages/alto_tui
mix deps.get
mix alto.tui --config ../../alto.agentic.exs
```

Use `--project PATH` to open a workspace, `--catalog PATH` for a separate task
catalog, `--credentials PATH` for a provider credential store, and `--log PATH`
for a diagnostic log. `mix alto.tui --help` lists the options.

You can supply your own `alto.exs` for each model or workflow. See the
[configuration guide](../../docs/configuration.md) for shared bases and multiple
profiles. Backend and provider entries for the TUI are described below.

## Everyday controls

`Ctrl+G` opens the gear menu and acts as a leader for the shortcuts below.

| Control | Action |
| --- | --- |
| Enter | Send a message, or queue one follow-up during a run |
| Shift+Enter | Insert a newline |
| Ctrl+Enter | Send the draft as a steer, or promote a queued follow-up |
| Ctrl+G, S | Promote the queued follow-up to steering |
| Esc | Close the current popup/drawer, or cancel the selected run |
| F2 | Select an approval mode |
| F3 / F4 / F5 | Select provider / model / backend |
| F6 | Switch prose/code entry |
| F7 / Ctrl+G, F | Upload, edit, or remove attachments |
| F8 / F9 | Approve / deny the pending request |
| Ctrl+G, R | Select supported reasoning effort |
| Ctrl+G, N | Start a new task in the current workspace |
| Ctrl+G, T | Open tasks |
| Ctrl+G, W | Open workspace actions |
| Ctrl+G, X | Close the selected workspace |
| Ctrl+G, D | Toggle the details pane or drawer |
| Ctrl+G, G | Edit the task goal |
| Ctrl+G, U | Inspect subagents |
| Ctrl+F | Search the loaded conversation |

While a turn runs, Enter queues one follow-up for that task. A second follow-up
stays in the composer until the queued one starts. Steering arrives at the next
safe model boundary after dispatched tools settle, when the backend supports
it. Cancellation, failure, or a session-save failure pauses queued input; press
Enter with an empty composer to send it. Queued input stays in memory for the
lifetime of the TUI.

Saved history remains viewable after a failed run, including when an unfinished
dispatch prevents safely resuming. The activity indicator shows model waits,
reasoning, tool execution, retries, and approval waits.

## Attachments and pastes

**F7** / **Ctrl+G, F** opens attachment management. Upload local text, images,
PDFs or other files; edit a text attachment and save it with **Ctrl+S**, or
cancel edits with **Esc**. Uploads are private copies, so editing them does not
change the original file.

Large composer pastes fold into editable UTF-8 files at 4,096 bytes or 20 newline
characters, split into 32 KB chunks. Configure this in `tui: [paste_fold_bytes:
4_096, paste_fold_lines: 20, paste_chunk_bytes: 32_000]`. **Ctrl+V** can stage
PNG/JPEG images from local Wayland/X11 clipboards; other paste shortcuts retain
the terminal's normal behavior.

Submission freezes the edited content. Queued follow-ups and steering retain
that snapshot, so later edits cannot change an already submitted message.
Unsupported media leaves the draft intact. Queued media is checked against the
running model, and a model switch does not inherit its predecessor's media
permissions. Declare capabilities for your actual models as described in
[configuration](../../docs/configuration.md#attachments-and-model-inputs).

Image and document outputs are saved as private files and shown by path. Saved
native history can recreate missing output files using stable content digests.
Staging-file retention, including abandoned drafts, belongs to the host.

## Approvals and goals

Use the labeled Approve/Deny buttons or F8/F9 for a pending request. The details
pane shows the command, file-change preview, or other prepared operation.
Approval authorizes that operation. An explicit F2 mode overrides the configured
native approval policy. AUTO also resolves waiting approvals immediately; Codex
sandbox changes take effect on its next turn.

REVIEW delegates a decision to a configured two-argument callback:

```elixir
[
  tui: [
    approval_reviewer: fn request, context ->
      MyClassifier.approve?(request, context)
    end
  ]
]
```

Merge this entry into your config, then select REVIEW. The callback receives the
prepared request and execution context. Return `true` / `:approve`, or `false` /
`{:deny, reason}`. Exceptions, invalid decisions, and timeouts do not approve.
`approval_timeout` bounds review time. Native callbacks receive tool context;
Codex callbacks receive `cwd`, `session_id`, and `metadata`.

The goal editor saves an objective on the selected task and provides Pause,
Resume, Complete, and Clear actions. Goals survive restarts and accompany the
next run's initial message. Goal controls apply to the next run; they do not
start or automatically continue work.

## Workspaces and tasks

Click a workspace in the sidebar to compose a new task there. Use **+ New
workspace** or **Ctrl+G, W → Open another folder** to open a folder. Relative
paths start from the current workspace; `~` addresses your home folder. Tab
completes paths, Up/Down selects suggestions, and Enter opens an existing
folder. **Ctrl+N** or **Create folder** creates the typed path, including missing
parents. **Ctrl+O** opens the folder chooser; **Ctrl+U** clears the field.

Opening or creating a workspace preserves your draft. Existing runs continue in
their original folders. Closing a workspace hides it without cancelling work or
deleting files, tasks, or history; reopen the folder to restore its tasks.

**Ctrl+G, W → Create worktree…** creates a linked Git worktree from committed
files. Choose a starting ref (HEAD by default) and optionally a new branch.
Alto opens a new task there when creation finishes. Worktrees are stored beside
the catalog and remembered across restarts; closing their workspace leaves them
on disk.

The details pane stays beside the conversation on wide terminals, with a
resizable seam. On narrow terminals it opens as a drawer. Esc closes it and
restores the previous focus.

## Reading, search, and clipboard

Assistant replies and reasoning render Markdown with styled headings, emphasis,
and syntax-colored code. Tool output uses a compact preview; search also exposes
longer retained tool details. Saved messages keep their original content.

Ctrl+F searches messages, code, and tool/edit details literally and without case
sensitivity. Enter / Shift+Enter, F3 / Shift+F3, or Down / Up selects the next /
previous match. Click a result excerpt to jump to it. Ctrl+U clears the query;
Esc closes search. Search retains up to 1,000 matches; `1000+` means the query
has more occurrences. Searching does not send input to the agent.

Drag to select text within a pane, composer, or form. Hold a drag at the top or
bottom of a conversation/details pane to scroll. **Ctrl+C** or **Alt+C** copies
selection; right-click opens a Copy menu. **Alt+drag** includes UI labels and
controls. Shift+drag uses your terminal's own selection behavior.

Copy uses desktop clipboard helpers when available, otherwise an OSC 52 request
that your terminal must allow. Paste with the terminal's usual shortcut.
Bracketed paste inserts multiline text without sending it. Ctrl+V reads the
local clipboard when a helper is available, including PNG/JPEG image attachments,
otherwise the last TUI selection.

## Providers and backends

`provider_profiles` configures selectable model providers. Each entry is an
`Alto.Harness.ProviderProfile` with a `{module, options}` provider. `models` is
`:discover` or a list of atom-keyed model catalog maps. For example:

```elixir
Alto.default_config()
|> Keyword.merge(
  provider_profiles: [
    %Alto.Harness.ProviderProfile{
      id: "local",
      label: "Local models",
      provider: {Alto.Providers.OpenAICompatible, base_url: "http://localhost:1234/v1"},
      models: [%{id: "coder", name: "Coder", context_length: 32_000}]
    }
  ],
  tui_backends: [alto: {Alto.TUI.Backends.Native, label: "Alto native"}]
)
```

Use the actual model ID from your server. Omitted labels and credential IDs use
the profile ID; an omitted default model uses the provider's `model` option.
Provider and model choices are remembered across tasks, workspace switches, and
restarts. Each backend/provider pair keeps its own model choice. Forms mask API
keys; Tab or Up/Down selects fields, Enter advances, and Ctrl+S submits.

Reasoning effort choices come from the selected model's capabilities. For an
explicit catalog, add `efforts: ["low", "high"]` with supported values. Choices
apply to the next turn and are remembered for this TUI session. Readable thinking
or reasoning summaries appear before answers and remain available in history.
OpenAI-compatible and native Anthropic adapters stream reasoning when supplied;
Codex can provide summaries. Encrypted or redacted data is not displayed.

`tui_backends` is the complete ordered backend list; include each backend you
want to offer:

```elixir
[
  tui_backends: [
    alto: {Alto.TUI.Backends.Native, label: "Alto native"},
    codex: {Alto.TUI.Backends.Codex, label: "Codex · ChatGPT", command: "codex"},
    custom: {MyBackend, []}
  ]
]
```

The supplied coding profile includes native Alto and Codex. Codex requires its
CLI to be installed and signed in. Saved tasks retain their backend identity;
configure that backend again to continue them. New tasks select the first entry.

Runner adapters implement `Alto.TUI.Backend.start/4` and `cancel/3`. Interactive
adapters implement `ui/3` and `cancel/3` to contribute connection setup, models,
approvals, streaming, and settings. Return `:pass` from UI callbacks to retain
host behavior. See `Alto.TUI.Backend` and the built-in implementations for the
callback shapes.

## Subagent inspection

Ctrl+G, U opens the task's child agents. Select one to see its model, parent,
stage, streamed activity, tool summaries, and result in the details pane. Esc
returns to task details without stopping the parent. Approvals keep priority.

Reopening a native task rebuilds saved child activity from session logs,
including failed and cancelled children. An absent completion record is shown
as **no saved completion**. Transient fragments that were never saved cannot be
reconstructed. See [subagents](../../docs/subagents.md) for team configuration.

## Logs and memory settings

Logs go to `$ALTO_STATE_HOME/alto/logs/tui.log`, then
`$XDG_STATE_HOME/alto/logs/tui.log`, or `~/.local/state/alto/logs/tui.log`.
Use `--log PATH` to override this location. Logs rotate at 5 MB with three
archives. Console logging is muted during the TUI and restored on exit.
Set `ALTO_REQUEST_DIAGNOSTICS=1` to enable the coding profile's request diagnostics.

Configure display caches in your `alto.exs`:

```elixir
[
  max_event_bytes: 8_000_000,
  tui: [render_cache_bytes: 16_000_000, history_cache_bytes: 12_000_000]
]
```

`render_cache_bytes` is a weighted serialized-size estimate; zero disables
caching. `history_cache_bytes` covers cached display entries and child activity.
The selected conversation, active runs, and queued input stay protected even
above that budget. These settings bound caches rather than total process RSS;
saved transcripts and session logs have their own retention settings.

For reproducible workloads, see [benchmarks](../../docs/benchmarks.md).
