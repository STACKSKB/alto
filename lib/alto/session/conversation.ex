defmodule Alto.Session.Conversation do
  @moduledoc """
  Immutable conversation revisions behind `Alto.Session` transcript snapshots.

  Each settled revision stores a complete, bounded transcript in its own file
  and links to its parent revision. The mutable transcript sidecar remains the
  fast branch head. Tool dispatches use a separate revision-bound fence so a
  crash cannot make ordinary resume replay effects whose outcome is unknown.
  """

  alias Alto.Context.Transcript
  alias Alto.{DurableLog, Session, Storage}

  @version 1
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
      path = transcript_path(opts, id)

      Storage.with_lock(lock_path(path), fn ->
        persist_locked(
          id,
          messages,
          transcript_bytes,
          expected,
          parent,
          summary,
          settled,
          resolved_operations,
          max_conversation_bytes,
          opts
        )
      end)
    end
  end

  @doc "Read the latest safe branch head for ordinary resume."
  @spec resume(Session.session_id(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def resume(id, opts \\ []) do
    with :ok <- Session.validate_id(id) do
      path = transcript_path(opts, id)

      Storage.with_lock(lock_path(path), fn ->
        with {:ok, snapshot} <- read_snapshot(id, opts),
             {:ok, fence} <- read_dispatch_fence(id, opts),
             :ok <- resume_safety(snapshot, fence, Keyword.get(opts, :allow_unsettled, false)) do
          result =
            if fence && fence.revision == snapshot.revision,
              do: Map.put(snapshot, :unsettled, fence),
              else: snapshot

          {:ok, result}
        end
      end)
    end
  end

  @doc "Read one retained revision without recursively materializing its ancestry."
  @spec fetch(Session.session_id(), :latest | revision(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def fetch(id, revision \\ :latest, opts \\ []) do
    with :ok <- Session.validate_id(id),
         {:ok, revision} <- requested_revision(revision) do
      path = transcript_path(opts, id)

      Storage.with_lock(lock_path(path), fn ->
        with {:ok, head} <- read_snapshot(id, opts),
             :ok <- check_expected(id, Keyword.get(opts, :expected_revision, :any), head.revision) do
          select_revision(id, revision, head, opts)
        end
      end)
    end
  end

  @doc "Fence a settled revision before any tool in the named batch is dispatched."
  @spec mark_dispatched(Session.session_id(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_dispatched(id, tool_call_ids, opts \\ []) do
    with :ok <- Session.validate_id(id),
         {:ok, ids} <- validate_tool_call_ids(tool_call_ids),
         {:ok, expected} <- expected_revision(Keyword.get(opts, :expected_revision, :any)) do
      path = transcript_path(opts, id)

      Storage.with_lock(lock_path(path), fn ->
        with {:ok, snapshot} <- read_snapshot(id, opts),
             :ok <- check_expected(id, expected, snapshot.revision),
             {:ok, current} <- read_dispatch_fence(id, opts),
             requested_fence <- %{
               revision: snapshot.revision,
               tool_call_ids: ids,
               run_id: Keyword.get(opts, :run_id),
               at_ms: System.system_time(:millisecond)
             },
             {:ok, fence} <- put_dispatch_fence(id, requested_fence, current, opts) do
          {:ok, fence}
        end
      end)
    end
  end

  defp persist_locked(
         id,
         messages,
         transcript_bytes,
         expected,
         requested_parent,
         summary,
         settled,
         resolved_operations,
         max_conversation_bytes,
         opts
       ) do
    with {:ok, current} <- current_snapshot(id, opts),
         current_revision <- if(current, do: current.revision, else: 0),
         retained_bytes <- if(current, do: current.conversation_bytes, else: 0),
         :ok <- check_expected(id, expected, current_revision),
         {:ok, fence} <- read_dispatch_fence(id, opts),
         :ok <-
           resolve_dispatch_fence(
             id,
             current_revision,
             fence,
             messages,
             settled,
             resolved_operations
           ),
         next_revision <- current_revision + 1,
         :ok <- validate_next_revision(id, next_revision),
         {:ok, parent} <- resolve_parent(id, current, requested_parent),
         entry <-
           entry(
             id,
             next_revision,
             parent,
             messages,
             transcript_bytes,
             summary,
             settled,
             retained_bytes
           ),
         entry <- Map.put(entry, "context_observation", Keyword.get(opts, :context_observation)),
         {:ok, encoded} <- encode_bounded(entry),
         conversation_bytes <- retained_bytes + byte_size(encoded),
         :ok <-
           check_conversation_bytes(
             id,
             conversation_bytes,
             max_conversation_bytes,
             byte_size(encoded)
           ),
         :ok <- put_entry(id, next_revision, encoded, opts),
         snapshot <- snapshot(entry, byte_size(encoded)),
         :ok <- put_snapshot(id, snapshot, opts) do
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

  defp entry(
         id,
         revision,
         parent,
         messages,
         transcript_bytes,
         summary,
         settled,
         retained_bytes
       ) do
    %{
      "v" => @version,
      "type" => "conversation_entry",
      "entry_id" => entry_id(id, revision),
      "session_id" => id,
      "revision" => revision,
      "parent" => encode_parent(parent),
      "summary" => summary,
      "settled" => settled,
      "retained_bytes_before" => retained_bytes,
      "messages" => messages,
      "transcript_bytes" => transcript_bytes,
      "at_ms" => System.system_time(:millisecond)
    }
  end

  defp snapshot(entry, entry_bytes) do
    %{
      messages: entry["messages"],
      context_observation: entry["context_observation"],
      transcript_bytes: entry["transcript_bytes"],
      revision: entry["revision"],
      entry_id: entry["entry_id"],
      entry_session_id: entry["session_id"],
      parent: decode_parent!(entry["parent"]),
      summary: entry["summary"],
      settled: entry["settled"],
      conversation_bytes: entry["retained_bytes_before"] + entry_bytes
    }
  end

  defp put_entry(id, revision, encoded, opts) do
    path = entry_path(opts, id, revision)

    with :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true) do
      case bounded_read(path, @max_entry_bytes) do
        {:ok, existing} ->
          existing_entry_result(existing, encoded, id, revision, path)

        {:error, :enoent} ->
          with :ok <- Storage.ensure_private_file(path),
               :ok <- DurableLog.replace(path, encoded) do
            :ok
          end

        {:error, reason} ->
          {:error, {:conversation_write_failed, reason}}
      end
    end
  end

  defp existing_entry_result("", encoded, _id, _revision, path),
    do: DurableLog.replace(path, encoded)

  defp existing_entry_result(existing, encoded, id, revision, _path) do
    with {:ok, old} when is_map(old) <- JSON.decode(existing),
         {:ok, new} when is_map(new) <- JSON.decode(encoded),
         true <- Map.drop(old, ["at_ms"]) == Map.drop(new, ["at_ms"]) do
      :ok
    else
      _ ->
        {:error, {:conversation_revision_conflict, %{session_id: id, revision: revision}}}
    end
  end

  defp put_snapshot(id, snapshot, opts) do
    record = %{
      "v" => @version,
      "revision" => snapshot.revision,
      "entry_id" => snapshot.entry_id,
      "parent" => encode_parent(snapshot.parent),
      "summary" => snapshot.summary,
      "settled" => snapshot.settled,
      "conversation_bytes" => snapshot.conversation_bytes,
      "messages" => snapshot.messages,
      "context_observation" => Map.get(snapshot, :context_observation),
      "transcript_bytes" => snapshot.transcript_bytes
    }

    with {:ok, encoded} <- encode_bounded(record),
         :ok <- Storage.ensure_private_dir(Session.dir(opts), owned: true),
         :ok <- Alto.Tools.AtomicWrite.write(transcript_path(opts, id), encoded <> "\n", 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:session_write_failed, reason}}
    end
  end

  defp read_snapshot(id, opts) do
    case bounded_read(transcript_path(opts, id), @max_entry_bytes) do
      {:ok, contents} -> decode_snapshot(String.trim(contents), id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_snapshot(contents, id) do
    with {:ok, record} when is_map(record) <- JSON.decode(contents),
         %{"messages" => messages, "transcript_bytes" => bytes} <- record,
         true <- is_list(messages) and is_integer(bytes) and bytes >= 0,
         revision when is_integer(revision) and revision >= 1 <- Map.get(record, "revision", 1),
         {:ok, settled} <- validate_messages(messages, true),
         true <- Map.get(record, "settled", settled) == settled,
         conversation_bytes when is_integer(conversation_bytes) and conversation_bytes >= 0 <-
           Map.get(record, "conversation_bytes", 0),
         {:ok, parent} <- optional_parent(Map.get(record, "parent")),
         {:ok, summary} <- optional_summary(Map.get(record, "summary")) do
      {:ok,
       %{
         messages: messages,
         context_observation: Map.get(record, "context_observation"),
         transcript_bytes: bytes,
         revision: revision,
         entry_id: Map.get(record, "entry_id", entry_id(id, revision)),
         entry_session_id: id,
         parent: parent,
         summary: summary,
         settled: settled,
         conversation_bytes: conversation_bytes
       }}
    else
      _ -> {:error, {:session_corrupt, id, :transcript}}
    end
  end

  defp select_revision(_id, :latest, head, _opts), do: {:ok, head}
  defp select_revision(_id, revision, %{revision: revision} = head, _opts), do: {:ok, head}

  defp select_revision(id, revision, _head, opts) do
    case bounded_read(entry_path(opts, id, revision), @max_entry_bytes) do
      {:ok, contents} -> decode_entry(contents, id, revision)
      {:error, :enoent} -> {:error, {:conversation_revision_not_found, id, revision}}
      {:error, reason} -> {:error, {:conversation_read_failed, reason}}
    end
  end

  defp decode_entry(contents, id, revision) do
    with {:ok, entry} when is_map(entry) <- JSON.decode(contents),
         true <- entry["type"] == "conversation_entry",
         true <- entry["session_id"] == id and entry["revision"] == revision,
         true <- entry["entry_id"] == entry_id(id, revision),
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
      current && current.revision == fence.revision &&
        current.run_id not in [nil, fence.run_id] && fence.run_id != nil ->
        {:error,
         {:conversation_dispatch_conflict,
          %{session_id: id, revision: fence.revision, current: current}}}

      current && current.revision == fence.revision &&
          current.tool_call_ids == fence.tool_call_ids ->
        {:ok, current}

      current && current.revision == fence.revision ->
        merged = %{
          fence
          | tool_call_ids: Enum.uniq(current.tool_call_ids ++ fence.tool_call_ids),
            run_id: current.run_id || fence.run_id
        }

        with {:ok, ids} <- validate_tool_call_ids(merged.tool_call_ids),
             merged <- %{merged | tool_call_ids: ids},
             :ok <- write_dispatch_fence(id, merged, opts) do
          {:ok, merged}
        end

      current && current.revision > fence.revision ->
        {:error,
         {:conversation_dispatch_conflict,
          %{session_id: id, revision: fence.revision, current: current}}}

      true ->
        with :ok <- write_dispatch_fence(id, fence, opts), do: {:ok, fence}
    end
  end

  defp write_dispatch_fence(id, fence, opts) do
    record = %{
      "v" => @version,
      "status" => "dispatched",
      "revision" => fence.revision,
      "tool_call_ids" => fence.tool_call_ids,
      "run_id" => fence.run_id,
      "at_ms" => fence.at_ms
    }

    with {:ok, encoded} <- encode_bounded(record),
         :ok <- Storage.ensure_private_dir(Session.dir(opts), owned: true),
         :ok <- Alto.Tools.AtomicWrite.write(dispatch_path(opts, id), encoded <> "\n", 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:conversation_write_failed, reason}}
    end
  end

  defp read_dispatch_fence(id, opts) do
    case bounded_read(dispatch_path(opts, id), @max_entry_bytes) do
      {:ok, contents} -> decode_dispatch_fence(String.trim(contents), id)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:conversation_read_failed, reason}}
    end
  end

  defp decode_dispatch_fence(contents, id) do
    with {:ok, record} when is_map(record) <- JSON.decode(contents),
         true <- record["status"] == "dispatched",
         revision when is_integer(revision) and revision >= 1 <- record["revision"],
         {:ok, ids} <- validate_tool_call_ids(record["tool_call_ids"]) do
      {:ok,
       %{
         revision: revision,
         tool_call_ids: ids,
         run_id: record["run_id"],
         at_ms: record["at_ms"]
       }}
    else
      _ -> {:error, {:session_corrupt, id, :dispatch}}
    end
  end

  defp resume_safety(snapshot, nil, _allow), do: validate_resumable(snapshot)

  defp resume_safety(snapshot, fence, allow) do
    cond do
      fence.revision < snapshot.revision ->
        validate_resumable(snapshot)

      fence.revision == snapshot.revision and allow == true ->
        validate_resumable(snapshot)

      fence.revision == snapshot.revision and not snapshot.settled and
          dispatched_calls_retained?(snapshot.messages, fence.tool_call_ids) ->
        validate_resumable(snapshot)

      fence.revision == snapshot.revision ->
        {:error,
         {:session_unsettled_tool_dispatch,
          %{
            session_id: snapshot.entry_session_id,
            revision: snapshot.revision,
            tool_call_ids: fence.tool_call_ids,
            run_id: fence.run_id
          }}}

      true ->
        {:error, {:session_corrupt, snapshot.entry_session_id, :dispatch}}
    end
  end

  defp validate_resumable(snapshot) do
    case validate_messages(snapshot.messages, true) do
      {:ok, settled} when settled == snapshot.settled -> :ok
      _ -> {:error, {:session_corrupt, snapshot.entry_session_id, :transcript}}
    end
  end

  defp validate_messages(messages, allow_pending) when is_list(messages) do
    if Enum.all?(messages, &is_map/1) do
      case Transcript.validate(messages) do
        :ok ->
          {:ok, true}

        {:error, {:unanswered_tool_calls, _}} = pending when allow_pending ->
          case Transcript.validate(messages, allow_pending: true) do
            :ok -> {:ok, false}
            _ -> pending
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_messages}
    end
  end

  defp validate_messages(_, _), do: {:error, :invalid_messages}

  defp dispatched_calls_retained?(messages, ids) do
    retained =
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

    Enum.all?(ids, &MapSet.member?(retained, &1))
  end

  defp resolve_dispatch_fence(_id, _revision, nil, _messages, _settled, _resolved), do: :ok

  defp resolve_dispatch_fence(id, revision, fence, messages, settled, resolved) do
    cond do
      fence.revision < revision ->
        :ok

      fence.revision > revision ->
        {:error, {:session_corrupt, id, :dispatch}}

      true ->
        retained = retained_outcome_ids(messages, settled)
        resolved = MapSet.union(retained, MapSet.new(resolved))
        unresolved = Enum.reject(fence.tool_call_ids, &MapSet.member?(resolved, &1))

        if unresolved == [] do
          :ok
        else
          {:error,
           {:conversation_unresolved_dispatch,
            %{session_id: id, revision: revision, operation_ids: unresolved}}}
        end
    end
  end

  defp retained_outcome_ids(messages, settled) do
    replies =
      messages
      |> Enum.flat_map(fn
        %{"role" => "tool", "tool_call_id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

    pending_calls =
      if settled do
        []
      else
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
      end

    MapSet.new(replies ++ pending_calls)
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
  defp dispatch_path(opts, id), do: Path.join(Session.dir(opts), id <> ".dispatch.json")

  defp entry_path(opts, id, revision) do
    Path.join([
      Session.dir(opts),
      "conversations",
      id,
      "revision-#{revision}.json"
    ])
  end

  defp lock_path(path), do: path <> ".lock"

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
end
