defmodule Alto.Session do
  @moduledoc """
  Exact-term JSONL session logs with immutable conversation revisions and an
  atomic transcript head. Dispatch fences block ordinary resume of uncertain effects.

  Session IDs cannot escape the storage directory. Started records exclude
  credentials; private records may contain sensitive prompts and tool output.
  Resume resolves credentials from current caller-owned configuration.

  Host audit logging is best-effort: append failures do not change the run outcome
  and results report degraded persistence. Listings return at most 100 sessions.
  """

  @version 1
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
          last_status: String.t() | nil
        }

  @doc "Resolve the sessions directory, honouring an explicit override."
  @spec dir(keyword()) :: Path.t()
  def dir(opts \\ []), do: Alto.Storage.dir("sessions", Keyword.get(opts, :session_dir))

  @doc "Generate a random session id without creating any records."
  @spec generate_id() :: session_id()
  def generate_id do
    "sess-" <> Base.encode32(:crypto.strong_rand_bytes(9), case: :lower, padding: false)
  end

  @doc "Check a session id for directory traversal and shape."
  @spec validate_id(term()) :: :ok | {:error, term()}
  def validate_id(id) do
    if Alto.Storage.valid_id?(id), do: :ok, else: {:error, {:invalid_session_id, id}}
  end

  @doc "Create a session for a task; returns its random id."
  @spec create(term(), map(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def create(task, meta \\ %{}, opts \\ []) do
    id = generate_id()

    record =
      meta
      |> Map.merge(%{task: task, subagent: false, session_owner: true})
      |> started_record()

    with :ok <- append(id, record, opts), do: {:ok, id}
  end

  @doc "Append one record map to a session log."
  @spec append(session_id(), record(), keyword()) :: :ok | {:error, term()}
  def append(id, record, opts \\ []) when is_map(record) do
    with :ok <- validate_id(id),
         {:ok, line} <- encode_line(record) do
      case Alto.Session.Writer.append(id, line, opts) do
        :unavailable -> append_direct(id, line, opts)
        result -> result
      end
    end
  end

  defp append_direct(id, line, opts) do
    path = log_path(dir(opts), id)

    with_lock(id, opts, fn ->
      with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(path), owned: true),
           :ok <- Alto.Storage.ensure_private_file(path),
           :ok <- Alto.DurableLog.append(path, line) do
        :ok
      else
        {:error, reason} -> {:error, {:session_write_failed, reason}}
      end
    end)
  end

  @doc false
  def with_lock(id, opts, fun) when is_function(fun, 0) do
    with :ok <- validate_id(id),
         do: Alto.Storage.with_lock(Path.join(dir(opts), id <> ".lock"), fun)
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

      case Alto.BoundedFile.read(path, @max_log_bytes) do
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
      page_events(id, opts, cursor, limit, run_id)
    end
  end

  @doc "Fetch the latest resumable transcript for a session."
  @spec transcript(session_id(), keyword()) :: {:ok, Conversation.snapshot()} | {:error, term()}
  def transcript(id, opts \\ []) do
    case Conversation.resume(id, opts) do
      {:ok, _snapshot} = result ->
        result

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
             conversation_retained_turns: :infinity,
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
         :ok <-
           Conversation.validate_fork_options(
             summary,
             Keyword.fetch!(opts, :max_conversation_bytes),
             Keyword.fetch!(opts, :conversation_retained_turns)
           ),
         true <- source["settled"],
         :ok <-
           append(
             destination,
             started_record(%{
               run_id: nil,
               parent_session_id: id,
               task: "Fork of #{id} at revision #{source["revision"]}",
               provider: nil,
               model: nil,
               cwd: nil
             }),
             opts
           ),
         :ok <- append(destination, forked_record(id, source["revision"], summary), opts),
         {:ok, branch} <-
           Conversation.persist(
             destination,
             source["messages"],
             source["transcript_bytes"],
             session_dir: Keyword.get(opts, :session_dir),
             expected_revision: 0,
             parent: %{"session_id" => id, "revision" => source["revision"]},
             summary: summary,
             conversation_retained_turns: Keyword.fetch!(opts, :conversation_retained_turns),
             max_conversation_bytes: Keyword.fetch!(opts, :max_conversation_bytes)
           ) do
      {:ok,
       %{
         session_id: destination,
         source: %{session_id: id, revision: source["revision"]},
         summary: summary,
         transcript: branch
       }}
    else
      {:error, keys} when is_list(keys) -> {:error, {:invalid_fork_options, keys}}
      {:error, _} = error -> error
      false -> {:error, {:conversation_revision_unsettled, id, revision}}
    end
  end

  @doc "Load the transcript and revision as options for a resumed run."
  def resume_options(id, opts \\ []) do
    with {:ok, snapshot} <- transcript(id, Keyword.take(opts, [:session_dir])) do
      {:ok, [session: id, resume: snapshot]}
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
          |> Enum.filter(&Alto.Storage.valid_id?/1)
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
         {:ok, term} <-
           Alto.Persistence.Codec.decode(encoded,
             max_bytes: @max_log_bytes,
             validate: &safe_term?/1
           ) do
      {:ok, term}
    else
      _ -> {:error, :invalid_term_payload}
    end
  end

  def decode_term(%{"$event_term" => 1} = data) do
    with {:ok, term} <-
           Alto.Persistence.EventCodec.decode(data,
             max_bytes: @max_log_bytes,
             validate: &safe_term?/1
           ) do
      {:ok, term}
    else
      _ -> {:error, :invalid_term_payload}
    end
  end

  def decode_term(other), do: {:error, {:invalid_term_payload, other}}

  @doc "Project either generation of saved event data without creating atoms."
  def event_data(%{"wire_data" => data}), do: {:ok, data}

  def event_data(%{"data" => %{"$event_term" => 1} = data}),
    do: Alto.Persistence.EventCodec.project(data, max_bytes: @max_log_bytes)

  def event_data(%{"data" => data}) do
    with {:ok, term} <- decode_term(data), do: {:ok, Alto.Protocol.encode_term(term)}
  end

  def event_data(_), do: {:error, :invalid_event_data}

  ## Records built by the execution host

  @doc false
  def diagnostic_record(run_id, event, data) do
    %{
      "v" => @version,
      "type" => "diagnostic",
      "run_id" => run_id,
      "event" => Atom.to_string(event),
      "at_ms" => System.system_time(:millisecond),
      "data" => Alto.Protocol.encode_term(data)
    }
  end

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
      "agent_id" => Map.get(fields, :agent_id),
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
      "data" => Alto.Persistence.EventCodec.encode(event.data)
    }
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
      "status" => Atom.to_string(Map.fetch!(fields, :status)),
      "reason" => maybe_term(Map.get(fields, :reason)),
      "output" => maybe_term(Map.get(fields, :output)),
      "model_requests" => Map.get(fields, :model_requests)
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

  defp page_events(id, opts, cursor, limit, run_id) do
    initial = %{records: 0, total: 0, candidates: 0, events: []}

    reducer = fn line, acc ->
      number = acc.records + 1

      with true <-
             number <= @max_records or {:error, {:session_too_many_records, id, @max_records}},
           {:ok, record} <- decode_line(line, id, number) do
        acc = %{acc | records: number}

        if record["type"] == "event" do
          ordinal = acc.total + 1
          matches = ordinal > cursor and (is_nil(run_id) or record["run_id"] == run_id)
          keep = matches and acc.candidates < limit

          events =
            if keep,
              do: [record |> Map.put("ordinal", ordinal) |> Alto.Retained.detach() | acc.events],
              else: acc.events

          {:ok,
           %{
             acc
             | total: ordinal,
               candidates: acc.candidates + if(matches, do: 1, else: 0),
               events: events
           }}
        else
          {:ok, acc}
        end
      end
    end

    case Alto.Session.LogScan.fold(
           log_path(dir(opts), id),
           @max_log_bytes,
           0,
           "",
           initial,
           initial,
           reducer,
           complete_only: false
         ) do
      {:ok, acc, _, _} ->
        events = Enum.reverse(acc.events)
        last = Map.get(List.last(events, %{}), "ordinal", cursor)
        complete = acc.candidates <= limit

        {:ok,
         %{
           events: events,
           next_cursor: if(complete, do: nil, else: last),
           last_cursor: last,
           high_watermark: acc.total,
           complete: complete,
           gap: cursor > acc.total
         }}

      {:error, :enoent} ->
        {:error, {:session_not_found, id}}

      {:error, {:too_large, size, max}} ->
        {:error, {:session_too_large, id, size, max}}

      {:error, {kind, _, _}} = error when kind in [:session_corrupt, :session_too_many_records] ->
        error

      {:error, reason} ->
        {:error, {:session_read_failed, reason}}
    end
  end

  defp maybe_term(nil), do: nil
  defp maybe_term(term), do: encode_term(term)

  defp preview_task(task) when is_binary(task), do: String.slice(task, 0, @max_task_preview)
  defp preview_task(task), do: task |> inspect() |> String.slice(0, @max_task_preview)

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

  defp log_path(dir, id), do: Path.join(dir, id <> ".jsonl")
  defp transcript_path(dir, id), do: Path.join(dir, id <> ".transcript.json")

  defp encode_line(record) do
    {:ok, JSON.encode!(record) <> "\n"}
  rescue
    error -> {:error, {:session_unencodable, Exception.message(error)}}
  end

  defp decode_lines(contents, id) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Alto.Result.traverse(fn
      {_line, number} when number > @max_records ->
        {:error, {:session_too_many_records, id, @max_records}}

      {line, number} ->
        decode_line(line, id, number)
    end)
  end

  defp decode_line(line, id, number) do
    case JSON.decode(line) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, {:session_corrupt, id, number}}
    end
  end

  defp safe_term?(term) when is_function(term), do: false
  defp safe_term?(term) when is_list(term), do: Enum.all?(term, &safe_term?/1)

  defp safe_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&safe_term?/1)

  defp safe_term?(term) when is_map(term),
    do: term |> Map.to_list() |> Enum.all?(fn {k, v} -> safe_term?(k) and safe_term?(v) end)

  defp safe_term?(_term), do: true

  defp mtime(dir, id) do
    case File.stat(log_path(dir, id), time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end

  defp summarize(id, opts) do
    with {:ok, records} <- read(id, opts) do
      started = for %{"type" => "started", "session_owner" => true} = r <- records, do: r
      completed = for %{"type" => "completed", "session_owner" => true} = r <- records, do: r
      first = List.first(started, %{})

      {:ok,
       %{
         id: id,
         started_at_ms: first["at_ms"],
         task: first["task"],
         parent_session_id: first["parent_session_id"],
         agent_identity: first["agent_identity"],
         runs: length(started),
         completed_runs: length(completed),
         last_status: List.last(completed, %{})["status"]
       }}
    end
  end
end
