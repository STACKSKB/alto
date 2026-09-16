defmodule Alto.Session do
  @moduledoc """
  Append-only JSONL session records for the execution host, plus a revisioned
  transcript sidecar for fast resume and immutable conversation revisions for
  settled-turn recovery and branching.

  One directory per state home, one `<id>.jsonl` log per session. Records are
  small JSON envelopes; arbitrary Elixir terms (event data, outcomes, outputs)
  travel as base64 `term_to_binary` payloads so the durable log is exact —
  exactness is recovered from here, never from the lossy front-end wire. The
  transcript snapshot (the only large record) lives in `<id>.transcript.json`
  instead of inline, so listing and reading sessions stays cheap.

  Session identity is random (`sess-…`) and validated on every entry point,
  so a hostile or mistyped id cannot escape the sessions directory. Credential
  values never enter the `started` record: it keeps the provider module and
  model name only. Prompts, tool output, and event data may contain sensitive
  content and are protected by private state files; resume re-resolves
  credentials through the normal caller-owned path.

  Crash boundary: settled transcript revisions are resumable before a run
  completes. A revision-bound dispatch fence blocks ordinary resume while any
  dispatched tool outcome is unknown, so effects are never replayed from an
  older safe snapshot. Logging itself is best-effort from the host's
  perspective: append failures must never change the run outcome, and the
  serial result reports them as degraded persistence.

  Bounds: record payloads inherit the host's bounds (tool results,
  transcripts, summaries). `list/1` returns at most 100 sessions,
  newest first.
  """

  @version 1
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @max_list_entries 100
  @max_task_preview 120
  @max_log_bytes 16_000_000
  @max_records 20_000

  alias Alto.Session.Conversation

  @type session_id :: String.t()
  @type record :: map()
  @type summary :: %{
          id: session_id(),
          started_at_ms: non_neg_integer() | nil,
          task: String.t() | nil,
          parent_session_id: session_id() | nil,
          agent_identity: map() | nil,
          runs: non_neg_integer(),
          completed_runs: non_neg_integer(),
          last_outcome: String.t() | nil
        }

  @doc "Resolve the sessions directory, honouring an explicit override."
  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []) do
    case Keyword.get(opts, :session_dir) do
      nil -> Path.join([state_home(), "alto", "sessions"])
      path when is_binary(path) -> path
    end
  end

  @doc "Generate a random session id without creating any records."
  @spec generate_id() :: session_id()
  def generate_id do
    "sess-" <> Base.encode32(:crypto.strong_rand_bytes(9), case: :lower, padding: false)
  end

  @doc "Check a session id for directory traversal and shape."
  @spec validate_id(term()) :: :ok | {:error, term()}
  def validate_id(id) when is_binary(id) do
    if valid_id?(id), do: :ok, else: {:error, {:invalid_session_id, id}}
  end

  def validate_id(id), do: {:error, {:invalid_session_id, id}}

  @doc "Create a session for a task; returns its random id."
  @spec create(term(), map(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def create(task, meta \\ %{}, opts \\ []) do
    id = generate_id()

    record = %{
      "v" => @version,
      "type" => "started",
      "at_ms" => System.system_time(:millisecond),
      "run_id" => Map.get(meta, :run_id),
      "parent_run_id" => Map.get(meta, :parent_run_id),
      "task" => preview_task(task),
      "provider" => Map.get(meta, :provider),
      "model" => Map.get(meta, :model),
      "cwd" => Map.get(meta, :cwd)
    }

    case append(id, record, opts) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Append one record map to a session log."
  @spec append(session_id(), record(), keyword()) :: :ok | {:error, term()}
  def append(id, record, opts \\ []) when is_map(record) do
    with :ok <- validate_id(id),
         {:ok, line} <- encode_line(record) do
      path = log_path(dir(opts), id)

      Alto.Storage.with_lock(lock_path(path), fn ->
        with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(path), owned: true),
             :ok <- Alto.Storage.ensure_private_file(path),
             :ok <- Alto.DurableLog.append(path, line) do
          :ok
        else
          {:error, reason} -> {:error, {:session_write_failed, reason}}
        end
      end)
    end
  end

  @doc "Write the transcript sidecar, optionally checking its current revision."
  @spec write_transcript(session_id(), [map()], non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def write_transcript(id, messages, transcript_bytes, opts \\ [])
      when is_list(messages) and is_integer(transcript_bytes) do
    case Conversation.persist(
           id,
           messages,
           transcript_bytes,
           Keyword.put(opts, :allow_pending, true)
         ) do
      {:ok, _snapshot} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Persist a safe settled boundary and return its new immutable revision."
  @spec persist_settled(session_id(), [map()], non_neg_integer(), keyword()) ::
          {:ok, Conversation.snapshot()} | {:error, term()}
  def persist_settled(id, messages, transcript_bytes, opts \\ []),
    do: Conversation.persist(id, messages, transcript_bytes, opts)

  @doc "Fence a settled revision before dispatching any tool in the batch."
  @spec mark_dispatched(session_id(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_dispatched(id, tool_call_ids, opts \\ []),
    do: Conversation.mark_dispatched(id, tool_call_ids, opts)

  @doc "Fetch one retained conversation revision without following its ancestry."
  @spec conversation(session_id(), :latest | pos_integer(), keyword()) ::
          {:ok, Conversation.snapshot()} | {:error, term()}
  def conversation(id, revision \\ :latest, opts \\ []),
    do: Conversation.fetch(id, revision, opts)

  @doc "Read and decode every record of a session log, oldest first."
  @spec read(session_id(), keyword()) :: {:ok, [record()]} | {:error, term()}
  def read(id, opts \\ []) do
    with :ok <- validate_id(id) do
      path = log_path(dir(opts), id)

      case bounded_read(path, @max_log_bytes) do
        {:ok, contents} -> decode_lines(contents, id)
        {:error, :enoent} -> {:error, {:session_not_found, id}}
        {:error, {:too_large, size, max}} -> {:error, {:session_too_large, id, size, max}}
        {:error, reason} -> {:error, {:session_read_failed, reason}}
      end
    end
  end

  @doc "Read a bounded page of durable event records using a stable event ordinal.

  `cursor` is the number of durable event ordinals already consumed; ordinals
  are independent of live registry sequence numbers. `complete` means the
  current page reached the session log's current end, not that the run
  completed. `last_cursor` and `high_watermark` remain available on complete
  pages so a client can poll for events appended later."
  @spec events(session_id(), keyword()) ::
          {:ok,
           %{
             events: [record()],
             next_cursor: non_neg_integer() | nil,
             last_cursor: non_neg_integer(),
             high_watermark: non_neg_integer(),
             complete: boolean(),
             gap: boolean()
           }}
          | {:error, term()}
  def events(id, opts \\ []) do
    with :ok <- validate_id(id),
         {:ok, cursor} <- event_cursor(Keyword.get(opts, :cursor, 0)),
         {:ok, limit} <- event_limit(Keyword.get(opts, :limit, 100)),
         {:ok, run_id} <- event_run_id(Keyword.get(opts, :run_id)) do
      path = log_path(dir(opts), id)

      case bounded_read(path, @max_log_bytes) do
        {:ok, contents} ->
          case decode_lines(contents, id) do
            {:ok, records} ->
              page_events(records, cursor, limit, run_id)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :enoent} ->
          {:error, {:session_not_found, id}}

        {:error, {:too_large, size, max}} ->
          {:error, {:session_too_large, id, size, max}}

        {:error, reason} ->
          {:error, {:session_read_failed, reason}}
      end
    end
  end

  @doc "Fetch the latest resumable transcript for a session."
  @spec transcript(session_id(), keyword()) ::
          {:ok,
           %{
             messages: [map()],
             transcript_bytes: non_neg_integer(),
             revision: pos_integer()
           }}
          | {:error, term()}
  def transcript(id, opts \\ []) do
    case Conversation.resume(id, opts) do
      {:ok, snapshot} ->
        {:ok, Map.take(snapshot, [:messages, :transcript_bytes, :revision, :unsettled])}

      {:error, :enoent} ->
        if File.exists?(log_path(dir(opts), id)) do
          {:error, :no_resumable_transcript}
        else
          {:error, {:session_not_found, id}}
        end

      {:error, {:too_large, size, max}} ->
        {:error, {:session_too_large, id, size, max}}

      {:error, {:session_corrupt, _, _}} = corrupt ->
        corrupt

      {:error, {:invalid_session_id, _}} = invalid ->
        invalid

      {:error, {:session_unsettled_tool_dispatch, _}} = unsettled ->
        unsettled

      {:error, reason} ->
        {:error, {:session_read_failed, reason}}
    end
  end

  @doc "Fork a retained complete revision into a new isolated session."
  @spec fork(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def fork(id, opts \\ [])

  def fork(id, opts) when is_list(opts) do
    {revision, opts} = Keyword.pop(opts, :revision, :latest)
    fork(id, revision, opts)
  end

  def fork(id, revision) when revision == :latest or is_integer(revision),
    do: fork(id, revision, [])

  @doc "Fork a specific retained complete revision into a new isolated session."
  @spec fork(session_id(), :latest | pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fork(id, revision, opts) when is_list(opts) do
    with {:ok, opts} <-
           Keyword.validate(opts,
             session_dir: nil,
             expected_revision: :any,
             summary: nil,
             session_id: nil,
             max_conversation_bytes: 128_000_000
           ),
         {:ok, source} <-
           Conversation.fetch(
             id,
             revision,
             Keyword.take(opts, [:session_dir, :expected_revision])
           ),
         destination <- Keyword.get(opts, :session_id) || generate_id(),
         :ok <- validate_id(destination),
         :ok <- branch_destination_available(destination, opts),
         summary <- Keyword.get(opts, :summary),
         :ok <- validate_fork_summary(summary),
         :ok <- validate_fork_storage_limit(Keyword.fetch!(opts, :max_conversation_bytes)),
         true <- source.settled,
         :ok <-
           append(
             destination,
             started_record(%{
               run_id: nil,
               parent_session_id: id,
               task: "Fork of #{id} at revision #{source.revision}",
               provider: nil,
               model: nil,
               cwd: nil
             }),
             opts
           ),
         :ok <- append(destination, forked_record(id, source.revision, summary), opts),
         {:ok, branch} <-
           Conversation.persist(
             destination,
             source.messages,
             source.transcript_bytes,
             session_dir: Keyword.get(opts, :session_dir),
             expected_revision: 0,
             parent: %{session_id: id, revision: source.revision},
             summary: summary,
             max_conversation_bytes: Keyword.fetch!(opts, :max_conversation_bytes)
           ) do
      {:ok,
       %{
         session_id: destination,
         source: %{session_id: id, revision: source.revision},
         summary: summary,
         transcript: Map.take(branch, [:messages, :transcript_bytes, :revision])
       }}
    else
      {:error, keys} when is_list(keys) -> {:error, {:invalid_fork_options, keys}}
      {:error, _} = error -> error
      false -> {:error, {:conversation_revision_unsettled, id, revision}}
    end
  end

  @doc "List sessions newest-first, capped for single-user convenience."
  @spec list(keyword()) :: {:ok, [summary()]} | {:error, term()}
  def list(opts \\ []) do
    case File.ls(dir(opts)) do
      {:ok, entries} ->
        summaries =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(&Path.rootname/1)
          |> Enum.filter(&valid_id?/1)
          |> Enum.map(fn id -> {id, mtime(dir(opts), id)} end)
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(@max_list_entries)
          |> Enum.flat_map(fn {id, _mtime} ->
            case summarize(id, opts) do
              {:ok, summary} -> [summary]
              {:error, _reason} -> []
            end
          end)

        {:ok, summaries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:session_read_failed, reason}}
    end
  end

  @doc "Exact term encoding for opaque payloads (event data, outcomes)."
  @spec encode_term(term()) :: map()
  def encode_term(term), do: %{"$term" => Base.encode64(:erlang.term_to_binary(term))}

  @doc "Decode an exact term payload."
  @spec decode_term(term()) :: {:ok, term()} | {:error, term()}
  def decode_term(%{"$term" => encoded}) when is_binary(encoded) do
    with true <- byte_size(encoded) <= @max_log_bytes,
         {:ok, binary} <- Base.decode64(encoded),
         true <- byte_size(binary) <= @max_log_bytes,
         false <- compressed_term?(binary),
         {:ok, term} <- safe_binary_to_term(binary),
         true <- :erlang.external_size(term) <= @max_log_bytes,
         true <- safe_term?(term) do
      {:ok, term}
    else
      :error -> {:error, :invalid_term_encoding}
      false -> {:error, :invalid_term_payload}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:invalid_term_payload, Exception.message(error)}}
  end

  def decode_term(other), do: {:error, {:invalid_term_payload, other}}

  ## Records built by the execution host

  @doc false
  @spec started_record(map()) :: record()
  def started_record(fields) do
    %{
      "v" => @version,
      "type" => "started",
      "at_ms" => System.system_time(:millisecond),
      "run_id" => Map.get(fields, :run_id),
      "parent_run_id" => Map.get(fields, :parent_run_id),
      "parent_session_id" => Map.get(fields, :parent_session_id),
      "agent_identity" => Alto.Protocol.encode_term(Map.get(fields, :agent_identity)),
      "subagent" => Map.get(fields, :subagent, false),
      "session_owner" => Map.get(fields, :session_owner, not Map.get(fields, :subagent, false)),
      "task" => preview_task(Map.get(fields, :task)),
      "provider" => Map.get(fields, :provider),
      "model" => Map.get(fields, :model),
      "cwd" => Map.get(fields, :cwd)
    }
  end

  @doc false
  @spec event_record(String.t(), Alto.Event.t()) :: record()
  def event_record(run_id, %Alto.Event{} = event) do
    %{
      "v" => @version,
      "type" => "event",
      "run_id" => run_id,
      "domain" => Atom.to_string(event.domain),
      "event" => Atom.to_string(event.type),
      "at_ms" => event.at_ms,
      "data" => encode_term(event.data)
    }
    |> with_wire_data(event.data)
  end

  # Keep an additive, self-contained projection for replay in a fresh VM.
  # Exact terms can contain atoms from application modules not loaded there;
  # replay must never loosen binary_to_term's safe decoding to recreate them.
  defp with_wire_data(record, data) do
    projection = Alto.Protocol.encode_term(data)
    _encoded = JSON.encode!(projection)
    Map.put(record, "wire_data", projection)
  rescue
    _error -> record
  end

  @doc false
  @spec completed_record(map()) :: record()
  def completed_record(fields) do
    %{
      "v" => @version,
      "type" => "completed",
      "run_id" => Map.get(fields, :run_id),
      "subagent" => Map.get(fields, :subagent, false),
      "session_owner" => Map.get(fields, :session_owner, not Map.get(fields, :subagent, false)),
      "outcome" => Map.get(fields, :outcome),
      "reason" => maybe_term(Map.get(fields, :reason)),
      "output" => maybe_term(Map.get(fields, :output)),
      "model_requests" => Map.get(fields, :model_requests)
    }
  end

  @doc false
  @spec compaction_record(map()) :: record()
  def compaction_record(fields) do
    %{
      "v" => @version,
      "type" => "compaction",
      "run_id" => Map.get(fields, :run_id),
      "at_ms" => System.system_time(:millisecond),
      "dropped_messages" => Map.get(fields, :dropped_messages),
      "dropped_bytes" => Map.get(fields, :dropped_bytes),
      "summary_bytes" => Map.get(fields, :summary_bytes),
      "summary" => Map.get(fields, :summary)
    }
  end

  @doc false
  @spec handoff_record(map()) :: record()
  def handoff_record(fields) do
    %{
      "v" => @version,
      "type" => "handoff",
      "run_id" => Map.get(fields, :run_id),
      "at_ms" => System.system_time(:millisecond),
      "dropped_messages" => Map.get(fields, :dropped_messages),
      "dropped_bytes" => Map.get(fields, :dropped_bytes),
      "handoff_bytes" => Map.get(fields, :handoff_bytes),
      "directory" => Map.get(fields, :directory),
      "files" => Map.get(fields, :files),
      "next_step" => Map.get(fields, :next_step)
    }
  end

  @doc false
  @spec forked_record(session_id(), pos_integer(), String.t() | nil) :: record()
  def forked_record(parent_session_id, parent_revision, summary) do
    %{
      "v" => @version,
      "type" => "forked",
      "at_ms" => System.system_time(:millisecond),
      "parent_session_id" => parent_session_id,
      "parent_revision" => parent_revision,
      "summary" => summary
    }
  end

  ## Internals

  defp event_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp event_cursor(cursor), do: {:error, {:invalid_event_cursor, cursor}}

  defp event_limit(limit) when is_integer(limit) and limit in 1..@max_list_entries,
    do: {:ok, limit}

  defp event_limit(limit), do: {:error, {:invalid_event_limit, limit}}

  defp event_run_id(nil), do: {:ok, nil}
  defp event_run_id(run_id) when is_binary(run_id) and run_id != "", do: {:ok, run_id}
  defp event_run_id(run_id), do: {:error, {:invalid_event_run_id, run_id}}

  defp page_events(records, cursor, limit, run_id) do
    candidates =
      records
      |> Enum.filter(&(&1["type"] == "event"))
      |> Enum.with_index(1)
      |> Enum.filter(fn {record, ordinal} ->
        ordinal > cursor and (is_nil(run_id) or record["run_id"] == run_id)
      end)

    events =
      candidates
      |> Enum.take(limit)
      |> Enum.map(fn {record, ordinal} -> Map.put(record, "ordinal", ordinal) end)

    last_ordinal = List.last(events) && Map.fetch!(List.last(events), "ordinal")
    complete = length(candidates) <= limit
    total = Enum.count(records, &(&1["type"] == "event"))
    last_cursor = last_ordinal || cursor

    {:ok,
     %{
       events: events,
       next_cursor: if(complete, do: nil, else: last_ordinal),
       last_cursor: last_cursor,
       high_watermark: total,
       complete: complete,
       gap: cursor > total
     }}
  end

  defp maybe_term(nil), do: nil
  defp maybe_term(term), do: encode_term(term)

  defp preview_task(task) when is_binary(task), do: String.slice(task, 0, @max_task_preview)
  defp preview_task(task), do: task |> inspect() |> String.slice(0, @max_task_preview)

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  defp branch_destination_available(id, opts) do
    root = dir(opts)
    conversation_dir = Path.join([root, "conversations", id])

    if File.exists?(log_path(root, id)) or File.exists?(transcript_path(root, id)) or
         File.exists?(conversation_dir) do
      {:error, {:session_already_exists, id}}
    else
      :ok
    end
  end

  defp validate_fork_summary(nil), do: :ok

  defp validate_fork_summary(summary) when is_binary(summary) do
    if summary != "" and String.valid?(summary) and byte_size(summary) <= 64_000,
      do: :ok,
      else: {:error, {:invalid_branch_summary, byte_size(summary)}}
  end

  defp validate_fork_summary(summary), do: {:error, {:invalid_branch_summary, summary}}

  defp validate_fork_storage_limit(max) when is_integer(max) and max > 0, do: :ok

  defp validate_fork_storage_limit(max),
    do: {:error, {:invalid_max_conversation_bytes, max}}

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")
  defp transcript_path(dir, id), do: Path.join(dir, id <> ".transcript.json")
  defp lock_path(path), do: path <> ".lock"

  defp state_home do
    case System.get_env("ALTO_STATE_HOME") do
      path when is_binary(path) and path != "" ->
        path

      _other ->
        case System.get_env("XDG_STATE_HOME") do
          path when is_binary(path) and path != "" -> path
          _other -> Path.join(System.user_home!(), ".local/state")
        end
    end
  end

  defp encode_line(record) do
    {:ok, JSON.encode!(record) <> "\n"}
  rescue
    error -> {:error, {:session_unencodable, Exception.message(error)}}
  end

  defp decode_lines(contents, id) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn
      {_line, number}, _acc when number > @max_records ->
        {:halt, {:error, {:session_too_many_records, id, @max_records}}}

      {line, number}, {:ok, records} ->
        case decode_line(line, id, number) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_line(line, id, number) do
    case JSON.decode(line) do
      {:ok, record} when is_map(record) -> {:ok, record}
      {:ok, _other} -> {:error, {:session_corrupt, id, number}}
      {:error, _error} -> {:error, {:session_corrupt, id, number}}
    end
  end

  defp bounded_read(path, max) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, max + 1) do
            {:error, reason} -> {:error, reason}
            :eof -> {:ok, <<>>}
            content when byte_size(content) > max -> {:error, {:too_large, max + 1, max}}
            content -> {:ok, content}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_binary_to_term(binary) do
    case :erlang.binary_to_term(binary, [:safe, :used]) do
      {term, used} when used == byte_size(binary) -> {:ok, term}
      {_term, _used} -> {:error, :invalid_term_payload}
    end
  rescue
    error -> {:error, {:invalid_term_payload, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_term_payload, {kind, reason}}}
  end

  defp safe_term?(term) when is_function(term), do: false
  defp safe_term?(term) when is_list(term), do: Enum.all?(term, &safe_term?/1)

  defp safe_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&safe_term?/1)

  defp safe_term?(term) when is_map(term),
    do: term |> Map.to_list() |> Enum.all?(fn {k, v} -> safe_term?(k) and safe_term?(v) end)

  defp safe_term?(_term), do: true

  defp compressed_term?(<<131, 80, _rest::binary>>), do: true
  defp compressed_term?(_binary), do: false

  defp mtime(dir, id) do
    case File.stat(log_path(dir, id), time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end

  defp summarize(id, opts) do
    with {:ok, records} <- read(id, opts) do
      # Legacy/shared child records do not own this session. Separate children
      # own their own transcript and listing while retaining their ancestry.
      root? = fn record ->
        Map.get(record, "session_owner", record["subagent"] != true) == true
      end

      started = Enum.find(records, &(&1["type"] == "started" and root?.(&1)))
      completed = Enum.filter(records, &(&1["type"] == "completed" and root?.(&1)))

      {:ok,
       %{
         id: id,
         started_at_ms: started && started["at_ms"],
         task: started && started["task"],
         parent_session_id: started && started["parent_session_id"],
         agent_identity: started && started["agent_identity"],
         runs: Enum.count(records, &(&1["type"] == "started" and root?.(&1))),
         completed_runs: length(completed),
         last_outcome: completed |> List.last() |> outcome_of()
       }}
    end
  end

  defp outcome_of(nil), do: nil
  defp outcome_of(%{"outcome" => outcome}), do: outcome
end
