defmodule Alto.Session.Conversation do
  @moduledoc """
  Immutable conversation revisions behind `Alto.Session` transcript snapshots.

  Each settled revision stores a complete, bounded transcript in its own file
  and links to its parent revision. The mutable transcript sidecar contains only the current revision
  pointer and its dispatch fence; the immutable entry owns the transcript. The fence ensures a
  crash cannot make ordinary resume replay effects whose outcome is unknown.
  """

  alias Alto.Context.Transcript
  alias Alto.{DurableLog, Session, Storage}

  @version 2
  @head_version 2
  @max_entry_bytes 16_000_000
  @default_max_conversation_bytes 128_000_000
  @max_revisions 20_000
  @max_summary_bytes 64_000
  @max_tool_calls 256
  @max_tool_call_id_bytes 512

  @type revision :: pos_integer()
  @type parent :: %{session_id: Session.session_id(), revision: revision()}
  @type snapshot :: %{
          required(:messages) => [map()],
          required(:transcript_bytes) => non_neg_integer(),
          required(:revision) => revision(),
          required(:entry_id) => String.t(),
          required(:entry_session_id) => Session.session_id(),
          required(:parent) => parent() | nil,
          required(:summary) => String.t() | nil,
          required(:settled) => boolean(),
          required(:conversation_bytes) => non_neg_integer(),
          optional(:unsettled) => map(),
          optional(:context_observation) => map() | nil
        }

  @doc false
  def validate_fork_options(summary, max_bytes) do
    with {:ok, _summary} <- optional_summary(summary),
         {:ok, _max_bytes} <- max_conversation_bytes(max_conversation_bytes: max_bytes),
         do: :ok
  end

  @doc "Persist one complete conversation boundary and advance the branch head."
  @spec persist(Session.session_id(), [map()], non_neg_integer(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def persist(id, messages, transcript_bytes, opts \\ []) do
    with :ok <- Session.validate_id(id),
         {:ok, allow_pending} <- boolean_option(opts, :allow_pending, false),
         {:ok, settled} <- validate_messages(messages, allow_pending),
         {:ok, resolved_operations} <-
           validate_resolved_operations(Keyword.get(opts, :resolved_operations, [])),
         :ok <- validate_transcript_bytes(transcript_bytes),
         {:ok, max_conversation_bytes} <- max_conversation_bytes(opts),
         {:ok, expected} <- expected_revision(Keyword.get(opts, :expected_revision, :any)),
         {:ok, parent} <- optional_parent(Keyword.get(opts, :parent)),
         {:ok, summary} <- optional_summary(Keyword.get(opts, :summary)) do
      draft = %{
        "v" => @version,
        "session_id" => id,
        "messages" => messages,
        "transcript_bytes" => transcript_bytes,
        "summary" => summary,
        "settled" => settled,
        "context_observation" => Keyword.get(opts, :context_observation)
      }

      constraints = %{
        expected: expected,
        requested_parent: parent,
        resolved_operations: resolved_operations,
        max_conversation_bytes: max_conversation_bytes
      }

      path = transcript_path(opts, id)

      Storage.with_lock(lock_path(path), fn ->
        persist_locked(draft, constraints, opts)
      end)
    end
  end

  @doc "Read the latest safe branch head for ordinary resume."
  @spec resume(Session.session_id(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def resume(id, opts \\ []) do
    with_snapshot(id, opts, fn snapshot ->
      with :ok <- resume_safety(snapshot, Keyword.get(opts, :allow_unsettled, false)),
           do: {:ok, snapshot}
    end)
  end

  @doc "Read one retained revision without recursively materializing its ancestry."
  @spec fetch(Session.session_id(), :latest | revision(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def fetch(id, revision \\ :latest, opts \\ []) do
    with {:ok, revision} <- requested_revision(revision) do
      with_snapshot(id, opts, fn head ->
        with :ok <-
               check_expected(id, Keyword.get(opts, :expected_revision, :any), head.revision),
             do: select_revision(id, revision, head, opts)
      end)
    end
  end

  @doc "Fence a settled revision before any tool in the named batch is dispatched."
  @spec mark_dispatched(Session.session_id(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_dispatched(id, tool_call_ids, opts \\ []) do
    with {:ok, ids} <- validate_tool_call_ids(tool_call_ids),
         {:ok, expected} <- expected_revision(Keyword.get(opts, :expected_revision, :any)) do
      with_snapshot(id, opts, fn snapshot ->
        with :ok <- check_expected(id, expected, snapshot.revision) do
          fence = %{
            revision: snapshot.revision,
            tool_call_ids: ids,
            run_id: Keyword.get(opts, :run_id),
            at_ms: System.system_time(:millisecond)
          }

          put_dispatch_fence(id, fence, Map.get(snapshot, :unsettled), opts)
        end
      end)
    end
  end

  defp with_snapshot(id, opts, fun) do
    with :ok <- Session.validate_id(id) do
      Storage.with_lock(lock_path(transcript_path(opts, id)), fn ->
        with {:ok, snapshot} <- read_snapshot(id, opts), do: fun.(snapshot)
      end)
    end
  end

  defp persist_locked(draft, constraints, opts) do
    id = draft["session_id"]

    with {:ok, current} <- current_snapshot(id, opts),
         current_revision <- if(current, do: current.revision, else: 0),
         retained_bytes <- if(current, do: current.conversation_bytes, else: 0),
         :ok <- check_expected(id, constraints.expected, current_revision),
         fence <- current && Map.get(current, :unsettled),
         :ok <-
           resolve_dispatch_fence(
             id,
             fence,
             draft["messages"],
             draft["settled"],
             constraints.resolved_operations
           ),
         next_revision <- current_revision + 1,
         :ok <- validate_next_revision(id, next_revision),
         {:ok, parent} <- resolve_parent(id, current, constraints.requested_parent),
         entry <-
           Map.merge(draft, %{
             "revision" => next_revision,
             "parent" => encode_parent(parent),
             "retained_bytes_before" => retained_bytes
           }),
         {:ok, encoded} <- encode_bounded(entry),
         conversation_bytes <- retained_bytes + byte_size(encoded),
         :ok <-
           check_conversation_bytes(
             id,
             conversation_bytes,
             constraints.max_conversation_bytes,
             byte_size(encoded)
           ),
         :ok <- put_entry(id, next_revision, entry, encoded, opts),
         snapshot <- snapshot(entry, byte_size(encoded)),
         :ok <- write_head(id, snapshot.revision, nil, opts) do
      {:ok, snapshot}
    end
  end

  defp current_snapshot(id, opts) do
    case read_snapshot(id, opts) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :enoent} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp resolve_parent(_id, nil, parent), do: {:ok, parent}

  defp resolve_parent(id, current, nil),
    do: {:ok, %{session_id: id, revision: current.revision}}

  defp resolve_parent(_id, current, requested) do
    own = %{session_id: current.entry_session_id, revision: current.revision}

    if requested == own,
      do: {:ok, own},
      else: {:error, {:conversation_parent_conflict, %{current: own, requested: requested}}}
  end

  defp snapshot(entry, entry_bytes) do
    %{
      messages: entry["messages"],
      context_observation: entry["context_observation"],
      transcript_bytes: entry["transcript_bytes"],
      revision: entry["revision"],
      entry_id: entry_id(entry["session_id"], entry["revision"]),
      entry_session_id: entry["session_id"],
      parent: decode_parent!(entry["parent"]),
      summary: entry["summary"],
      settled: entry["settled"],
      conversation_bytes: entry["retained_bytes_before"] + entry_bytes
    }
  end

  defp put_entry(id, revision, entry, encoded, opts) do
    path = entry_path(opts, id, revision)

    with :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true) do
      case Alto.BoundedFile.read(path, @max_entry_bytes) do
        {:ok, ""} ->
          DurableLog.replace(path, encoded)

        {:ok, existing} ->
          case JSON.decode(existing) do
            {:ok, ^entry} ->
              :ok

            _ ->
              {:error, {:conversation_revision_conflict, %{session_id: id, revision: revision}}}
          end

        {:error, :enoent} ->
          with :ok <- Storage.ensure_private_file(path), do: DurableLog.replace(path, encoded)

        {:error, reason} ->
          {:error, {:conversation_write_failed, reason}}
      end
    end
  end

  defp write_head(id, revision, fence, opts) do
    path = transcript_path(opts, id)

    record = %{
      "v" => @head_version,
      "revision" => revision,
      "dispatch" => fence && Map.delete(fence, :revision)
    }

    with {:ok, encoded} <- encode_bounded(record),
         :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true),
         :ok <- Alto.AtomicFile.write(path, encoded <> "\n", mode: 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:session_write_failed, reason}}
    end
  end

  defp read_snapshot(id, opts) do
    with {:ok, contents} <- Alto.BoundedFile.read(transcript_path(opts, id), @max_entry_bytes) do
      with {:ok, %{"v" => @head_version, "revision" => revision, "dispatch" => dispatch}} <-
             JSON.decode(contents),
           {:ok, revision} when is_integer(revision) <- requested_revision(revision),
           {:ok, fence} <- decode_dispatch_fence(dispatch, revision) do
        with {:ok, snapshot} <- select_revision(id, revision, nil, opts),
             do: {:ok, if(fence, do: Map.put(snapshot, :unsettled, fence), else: snapshot)}
      else
        _ -> {:error, {:session_corrupt, id, :transcript}}
      end
    end
  end

  defp select_revision(_id, :latest, head, _opts), do: {:ok, head}
  defp select_revision(_id, revision, %{revision: revision} = head, _opts), do: {:ok, head}

  defp select_revision(id, revision, _head, opts) do
    case Alto.BoundedFile.read(entry_path(opts, id, revision), @max_entry_bytes) do
      {:ok, contents} -> decode_entry(contents, id, revision)
      {:error, :enoent} -> {:error, {:conversation_revision_not_found, id, revision}}
      {:error, reason} -> {:error, {:conversation_read_failed, reason}}
    end
  end

  defp decode_entry(contents, id, revision) do
    with {:ok, entry} when is_map(entry) <- JSON.decode(contents),
         true <- entry["v"] == @version,
         true <- entry["session_id"] == id and entry["revision"] == revision,
         true <- is_list(entry["messages"]),
         true <- is_integer(entry["transcript_bytes"]) and entry["transcript_bytes"] >= 0,
         {:ok, settled} <- validate_messages(entry["messages"], true),
         true <- entry["settled"] == settled,
         retained when is_integer(retained) and retained >= 0 <- entry["retained_bytes_before"],
         {:ok, _parent} <- optional_parent(entry["parent"]),
         {:ok, _summary} <- optional_summary(entry["summary"]) do
      {:ok, snapshot(entry, byte_size(contents))}
    else
      _ -> {:error, {:conversation_corrupt, id, revision}}
    end
  end

  defp put_dispatch_fence(id, fence, current, opts) do
    cond do
      current && current.run_id not in [nil, fence.run_id] && fence.run_id != nil ->
        {:error,
         {:conversation_dispatch_conflict,
          %{session_id: id, revision: fence.revision, current: current}}}

      current && current.tool_call_ids == fence.tool_call_ids ->
        {:ok, current}

      true ->
        merged =
          if current do
            %{
              fence
              | tool_call_ids: Enum.uniq(current.tool_call_ids ++ fence.tool_call_ids),
                run_id: current.run_id || fence.run_id
            }
          else
            fence
          end

        with {:ok, _ids} <- validate_tool_call_ids(merged.tool_call_ids),
             :ok <- write_head(id, merged.revision, merged, opts),
             do: {:ok, merged}
    end
  end

  defp decode_dispatch_fence(nil, _revision), do: {:ok, nil}

  defp decode_dispatch_fence(record, revision) when is_map(record) do
    with {:ok, ids} <- validate_tool_call_ids(record["tool_call_ids"]) do
      {:ok,
       %{revision: revision, tool_call_ids: ids, run_id: record["run_id"], at_ms: record["at_ms"]}}
    end
  end

  defp decode_dispatch_fence(_, _), do: {:error, :invalid_dispatch}

  defp resume_safety(%{unsettled: fence} = snapshot, allow) do
    if allow == true or
         (not snapshot.settled and
            dispatched_calls_retained?(snapshot.messages, fence.tool_call_ids)) do
      :ok
    else
      {:error,
       {:session_unsettled_tool_dispatch,
        %{
          session_id: snapshot.entry_session_id,
          revision: snapshot.revision,
          tool_call_ids: fence.tool_call_ids,
          run_id: fence.run_id
        }}}
    end
  end

  defp resume_safety(_snapshot, _allow), do: :ok

  defp validate_messages(messages, allow_pending) do
    with {:ok, pending} <- Transcript.pending_calls(messages) do
      if pending == %{} or allow_pending,
        do: {:ok, pending == %{}},
        else: {:error, {:unanswered_tool_calls, Map.keys(pending)}}
    end
  end

  defp dispatched_calls_retained?(messages, ids) do
    retained = provider_call_ids(messages)

    Enum.all?(ids, &MapSet.member?(retained, &1))
  end

  defp resolve_dispatch_fence(_id, nil, _messages, _settled, _resolved), do: :ok

  defp resolve_dispatch_fence(id, fence, messages, settled, resolved) do
    resolved = MapSet.union(retained_outcome_ids(messages, settled), MapSet.new(resolved))
    unresolved = Enum.reject(fence.tool_call_ids, &MapSet.member?(resolved, &1))

    if unresolved == [] do
      :ok
    else
      {:error,
       {:conversation_unresolved_dispatch,
        %{session_id: id, revision: fence.revision, operation_ids: unresolved}}}
    end
  end

  defp retained_outcome_ids(messages, settled) do
    replies =
      messages
      |> Enum.flat_map(fn
        %{"role" => "tool", "tool_call_id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

    replies = MapSet.new(replies)
    if settled, do: replies, else: MapSet.union(replies, provider_call_ids(messages))
  end

  defp provider_call_ids(messages) do
    messages
    |> Enum.flat_map(fn
      %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
        Enum.flat_map(calls, fn
          %{"id" => id} when is_binary(id) -> [id]
          _ -> []
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp validate_transcript_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: :ok
  defp validate_transcript_bytes(bytes), do: {:error, {:invalid_transcript_bytes, bytes}}

  defp max_conversation_bytes(opts) do
    case Keyword.get(opts, :max_conversation_bytes, @default_max_conversation_bytes) do
      max when is_integer(max) and max > 0 -> {:ok, max}
      max -> {:error, {:invalid_max_conversation_bytes, max}}
    end
  end

  defp check_conversation_bytes(_id, total, max, _entry_bytes) when total <= max, do: :ok

  defp check_conversation_bytes(id, total, max, entry_bytes) do
    {:error,
     {:conversation_storage_limit,
      %{
        session_id: id,
        retained_bytes: total - entry_bytes,
        entry_bytes: entry_bytes,
        attempted_bytes: total,
        max_bytes: max
      }}}
  end

  defp boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, {:invalid_conversation_option, key, value}}
    end
  end

  defp validate_next_revision(_id, revision) when revision in 1..@max_revisions, do: :ok

  defp validate_next_revision(id, revision),
    do: {:error, {:conversation_revision_limit, id, revision, @max_revisions}}

  defp expected_revision(:any), do: {:ok, :any}
  defp expected_revision(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp expected_revision(value), do: {:error, {:invalid_expected_revision, value}}

  defp requested_revision(:latest), do: {:ok, :latest}

  defp requested_revision(revision) when is_integer(revision) and revision in 1..@max_revisions,
    do: {:ok, revision}

  defp requested_revision(revision), do: {:error, {:invalid_conversation_revision, revision}}

  defp check_expected(_id, :any, _current), do: :ok
  defp check_expected(_id, revision, revision), do: :ok

  defp check_expected(id, expected, current) do
    {:error,
     {:session_conflict,
      %{session_id: id, expected_revision: expected, current_revision: current}}}
  end

  defp optional_parent(nil), do: {:ok, nil}

  defp optional_parent(%{session_id: id, revision: revision}),
    do: validate_parent(id, revision)

  defp optional_parent(%{"session_id" => id, "revision" => revision}),
    do: validate_parent(id, revision)

  defp optional_parent(parent), do: {:error, {:invalid_conversation_parent, parent}}

  defp validate_parent(id, revision) do
    with :ok <- Session.validate_id(id),
         true <- is_integer(revision) and revision in 1..@max_revisions do
      {:ok, %{session_id: id, revision: revision}}
    else
      _ -> {:error, {:invalid_conversation_parent, %{session_id: id, revision: revision}}}
    end
  end

  defp optional_summary(nil), do: {:ok, nil}

  defp optional_summary(summary) when is_binary(summary) do
    if summary != "" and String.valid?(summary) and byte_size(summary) <= @max_summary_bytes,
      do: {:ok, summary},
      else: {:error, {:invalid_branch_summary, summary_size(summary)}}
  end

  defp optional_summary(summary), do: {:error, {:invalid_branch_summary, summary}}

  defp summary_size(summary) when is_binary(summary), do: byte_size(summary)
  defp summary_size(summary), do: summary

  defp validate_tool_call_ids(ids) when is_list(ids) and length(ids) in 1..@max_tool_calls do
    unique = Enum.uniq(ids)

    if length(unique) == length(ids) and
         Enum.all?(ids, fn id ->
           is_binary(id) and id != "" and String.valid?(id) and
             byte_size(id) <= @max_tool_call_id_bytes
         end) do
      {:ok, ids}
    else
      {:error, {:invalid_tool_call_ids, ids}}
    end
  end

  defp validate_tool_call_ids(ids), do: {:error, {:invalid_tool_call_ids, ids}}

  defp validate_resolved_operations([]), do: {:ok, []}
  defp validate_resolved_operations(ids), do: validate_tool_call_ids(ids)

  defp encode_parent(nil), do: nil

  defp encode_parent(parent),
    do: %{"session_id" => parent.session_id, "revision" => parent.revision}

  defp decode_parent!(nil), do: nil

  defp decode_parent!(parent),
    do: %{session_id: parent["session_id"], revision: parent["revision"]}

  defp encode_bounded(record) do
    encoded = JSON.encode!(record)

    if byte_size(encoded) <= @max_entry_bytes,
      do: {:ok, encoded},
      else: {:error, {:conversation_too_large, byte_size(encoded), @max_entry_bytes}}
  rescue
    error -> {:error, {:session_unencodable, Exception.message(error)}}
  end

  defp entry_id(id, revision), do: id <> ":" <> Integer.to_string(revision)

  defp transcript_path(opts, id), do: Path.join(Session.dir(opts), id <> ".transcript.json")

  defp entry_path(opts, id, revision) do
    Path.join([
      Session.dir(opts),
      "conversations",
      id,
      "revision-#{revision}.json"
    ])
  end

  defp lock_path(path), do: path <> ".lock"
end
