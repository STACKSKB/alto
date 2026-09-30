defmodule Alto.Session.Conversation do
  @moduledoc """
  Immutable conversation revisions behind the atomic `Alto.Session` transcript
  head. Its dispatch fence prevents replay of effects whose outcome is unknown.
  """

  alias Alto.Context.Transcript
  alias Alto.{DurableLog, Session, Storage}
  alias Alto.Session.Conversation.Store

  @version 5
  @max_entry_bytes 16_000_000
  @max_head_bytes @max_entry_bytes + 1_000_000
  @default_max_conversation_bytes 128_000_000
  @max_revisions 9_007_199_254_740_991
  @max_summary_bytes 64_000
  @max_tool_calls 256
  @max_tool_call_id_bytes 512

  @type revision :: pos_integer()
  @type parent :: %{required(String.t()) => Session.session_id() | revision()}
  @type snapshot :: %{required(String.t()) => term()}

  @doc false
  def validate_fork_options(summary, max_bytes, retention \\ :infinity) do
    with {:ok, _summary} <- optional_summary(summary),
         {:ok, _max_bytes} <- max_conversation_bytes(max_conversation_bytes: max_bytes),
         {:ok, _} <- retained_turns(conversation_retained_turns: retention),
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
         {:ok, retained_turns} <- retained_turns(opts),
         {:ok, turn_id} <- turn_id(Keyword.get(opts, :conversation_turn_id)),
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
        "context_observation" => Keyword.get(opts, :context_observation),
        "dispatch" => nil
      }

      constraints = %{
        expected: expected,
        requested_parent: parent,
        resolved_operations: resolved_operations,
        max_conversation_bytes: max_conversation_bytes,
        retained_turns: retained_turns,
        turn_id: turn_id
      }

      Session.with_lock(id, opts, fn -> persist_locked(draft, constraints, opts) end)
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

  @doc false
  def checkpoint_reference(id, revision, messages_rev, opts) do
    with_snapshot(id, opts, fn snapshot ->
      if snapshot["v"] == 5 and snapshot["revision"] == revision and
           Enum.reverse(snapshot["messages"]) == messages_rev do
        {:ok, reference(snapshot)}
      else
        {:ok, :inline}
      end
    end)
    |> case do
      {:error, :enoent} -> {:ok, :inline}
      other -> other
    end
  end

  @doc false
  def checkpoint_messages(id, expected, opts) do
    with_snapshot(id, opts, fn snapshot ->
      # A valid checkpoint always names the current head, which pins every
      # object it needs. Advancing/pruning that head invalidates the checkpoint
      # under the existing restore contract, before another effect can run.
      with true <- reference(snapshot) == expected,
           :ok <- resume_safety(snapshot, false) do
        {:ok, Enum.reverse(snapshot["messages"])}
      else
        _ -> {:error, :checkpoint_mismatch}
      end
    end)
  end

  defp reference(snapshot) do
    snapshot
    |> Map.take(~w(session_id revision message_root message_count))
    |> Map.put("$conversation", 1)
  end

  @doc "Convert retained snapshots in place without changing revisions or dispatch fences."
  def compact(id, opts \\ []) do
    Session.with_lock(id, opts, fn ->
      with {:ok, current, encoded} <- current_head(id, opts),
           true <- not is_nil(current),
           {:ok, limit} <- retained_turns(opts),
           :ok <- migrate_archives(id, opts),
           {:ok, record, _} <- incremental_current(current, encoded, opts),
           record <- Map.put(record, "retained_turns", limit),
           {:ok, pruning} <- Store.retention(id, record, limit, opts),
           {:ok, disk_bytes} <- Store.disk_bytes(id, opts),
           record <- Map.put(record, "retained_bytes_before", disk_bytes - pruning.bytes),
           {:ok, encoded} <- encode_bounded(record),
           :ok <- write_encoded_head(id, encoded, opts),
           :ok <- Store.prune(pruning) do
        {:ok,
         Map.put(record, "conversation_bytes", disk_bytes - pruning.bytes + byte_size(encoded))}
      else
        false -> {:error, :enoent}
        error -> error
      end
    end)
  end

  @doc "Read one retained revision, sharing unchanged message objects with other revisions."
  @spec fetch(Session.session_id(), :latest | revision(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def fetch(id, revision \\ :latest, opts \\ []) do
    # The head is atomically replaced and revisions are immutable. A viewer can
    # read either complete head without spawning flock or waiting for a writer.
    # Execution/resume and all mutations retain their locks and revision checks.
    with :ok <- Session.validate_id(id),
         {:ok, contents} <- Alto.BoundedFile.read(transcript_path(opts, id), @max_head_bytes),
         {:ok, record} when is_map(record) <- JSON.decode(contents) do
      # Finite retention can reclaim objects after advancing the head. Pin
      # readers with the same lock only for sessions using that policy.
      if is_integer(record["retained_turns"]) do
        Session.with_lock(id, opts, fn -> fetch_unlocked(id, revision, opts) end)
      else
        case fetch_unlocked(id, revision, opts) do
          {:ok, _} = result ->
            result

          _ ->
            # A writer may have switched from unlimited to finite retention
            # after our policy read. Retry under the lock before reporting loss.
            Session.with_lock(id, opts, fn -> fetch_unlocked(id, revision, opts) end)
        end
      end
    else
      {:error, :enoent} -> missing_head(id, opts)
      {:error, {:invalid_session_id, _}} = error -> error
      {:error, {:too_large, _, _}} = error -> error
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, {:session_corrupt, id, :transcript}}
    end
  end

  defp fetch_unlocked(id, revision, opts) do
    with :ok <- Session.validate_id(id),
         {:ok, revision} <- requested_revision(revision),
         {:ok, head} <- read_head(id, opts),
         :ok <- check_expected(id, Keyword.get(opts, :expected_revision, :any), head["revision"]),
         do: select_revision(id, revision, head, opts)
  end

  @doc "Fence a settled revision before any tool in the named batch is dispatched."
  @spec mark_dispatched(Session.session_id(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_dispatched(id, tool_call_ids, opts \\ []) do
    with {:ok, ids} <- validate_tool_call_ids(tool_call_ids),
         {:ok, expected} <- expected_revision(Keyword.get(opts, :expected_revision, :any)) do
      with_snapshot(id, opts, fn snapshot ->
        with :ok <- check_expected(id, expected, snapshot["revision"]) do
          fence = %{
            "revision" => snapshot["revision"],
            "tool_call_ids" => ids,
            "run_id" => Keyword.get(opts, :run_id),
            "at_ms" => System.system_time(:millisecond)
          }

          put_dispatch_fence(id, fence, snapshot, opts)
        end
      end)
    end
  end

  defp with_snapshot(id, opts, fun) do
    Session.with_lock(id, opts, fn ->
      with {:ok, head} <- read_head(id, opts), do: fun.(head)
    end)
  end

  defp persist_locked(draft, constraints, opts) do
    id = draft["session_id"]

    with {:ok, current, current_encoded} <- current_head(id, opts),
         current_revision <- if(current, do: current["revision"], else: 0),
         :ok <- check_expected(id, constraints.expected, current_revision),
         fence <- current && Map.get(current, "dispatch"),
         :ok <-
           resolve_dispatch_fence(
             id,
             fence,
             draft["messages"],
             draft["settled"],
             constraints.resolved_operations
           ),
         {:ok, parent} <- resolve_parent(id, current, constraints.requested_parent) do
      if unchanged?(draft, current, constraints) do
        {:ok, current}
      else
        commit(draft, current, current_encoded, parent, constraints, opts)
      end
    end
  end

  defp unchanged?(_draft, nil, _), do: false

  defp unchanged?(draft, current, constraints) do
    current["v"] == @version and current["dispatch"] == nil and
      Enum.all?(
        ~w(messages transcript_bytes summary context_observation settled),
        &(draft[&1] == current[&1])
      ) and
      current["retained_turns"] == constraints.retained_turns and
      (constraints.turn_id == nil or current["turn_id"] == constraints.turn_id)
  end

  defp commit(draft, current, current_encoded, parent, constraints, opts) do
    id = draft["session_id"]
    revision = if(current, do: current["revision"] + 1, else: 1)
    turn = next_turn(current, draft["messages"], constraints.turn_id)

    keep_current =
      current &&
        (constraints.retained_turns == nil or
           current_turn(current) >= max(turn - constraints.retained_turns + 1, 1))

    with :ok <- validate_next_revision(id, revision),
         # Preserve the existing decoded-transcript size bound independently
         # of how little space the incremental representation occupies.
         {:ok, _} <- encode_bounded(draft),
         :ok <- if(current && current["v"] == 4, do: migrate_archives(id, opts), else: :ok),
         {:ok, current, current_encoded} <- incremental_current(current, current_encoded, opts),
         {:ok, plan} <- Store.plan(id, draft["messages"], opts),
         {:ok, disk_bytes} <- Store.disk_bytes(id, opts),
         {:ok, archive_bytes} <- archive_size(id, current, current_encoded, keep_current, opts),
         record <-
           Map.merge(draft, %{
             "revision" => revision,
             "parent" => parent,
             "message_root" => plan.root,
             "message_count" => plan.count,
             "turn" => turn,
             "turn_id" => constraints.turn_id,
             "retained_turns" => constraints.retained_turns,
             "retained_bytes_before" => disk_bytes + plan.added_bytes + archive_bytes
           }),
         {:ok, pruning} <-
           retention(id, record, current, keep_current, plan, constraints.retained_turns, opts),
         record <- Map.update!(record, "retained_bytes_before", &(&1 - pruning.bytes)),
         {:ok, encoded} <- encode_bounded(record),
         total <- record["retained_bytes_before"] + byte_size(encoded),
         :ok <-
           check_conversation_bytes(
             id,
             total,
             constraints.max_conversation_bytes,
             byte_size(encoded) + plan.added_bytes
           ),
         :ok <- Store.write(plan),
         :ok <-
           if(keep_current, do: archive_current(id, current, current_encoded, opts), else: :ok),
         :ok <- write_encoded_head(id, encoded, opts),
         :ok <- Store.prune(pruning) do
      {:ok, Map.put(record, "conversation_bytes", total)}
    end
  end

  defp incremental_current(nil, encoded, _), do: {:ok, nil, encoded}
  defp incremental_current(%{"v" => 5} = current, encoded, _), do: {:ok, current, encoded}

  defp incremental_current(current, _encoded, opts) do
    with {:ok, plan} <- Store.plan(current["session_id"], current["messages"], opts),
         record <-
           Map.merge(current, %{
             "v" => @version,
             "message_root" => plan.root,
             "message_count" => plan.count,
             "turn" => current_turn(current),
             "turn_id" => nil,
             "retained_turns" => nil
           }),
         {:ok, encoded} <- encode_bounded(Map.put(record, "dispatch", nil)),
         :ok <- Store.write(plan),
         do: {:ok, record, encoded}
  end

  defp archive_size(_id, _current, _encoded, nil, _opts), do: {:ok, 0}
  defp archive_size(_id, _current, _encoded, false, _opts), do: {:ok, 0}

  defp archive_size(id, current, encoded, true, opts) do
    case Alto.BoundedFile.read(entry_path(opts, id, current["revision"]), @max_entry_bytes) do
      {:error, :enoent} ->
        {:ok, byte_size(encoded)}

      {:ok, ^encoded} ->
        {:ok, 0}

      _ ->
        {:error,
         {:conversation_revision_conflict, %{session_id: id, revision: current["revision"]}}}
    end
  end

  defp retention(_id, _record, _current, _keep, _plan, nil, _opts),
    do: {:ok, %{files: [], bytes: 0}}

  defp retention(id, record, current, keep, plan, limit, opts) do
    Store.retention(
      id,
      record,
      limit,
      opts
      |> Keyword.put(:conversation_objects, plan.objects)
      |> Keyword.put(:conversation_pins, if(keep, do: [current], else: []))
    )
  end

  defp next_turn(nil, messages, _), do: max(Enum.count(messages, &(&1["role"] == "user")), 1)

  defp next_turn(current, messages, nil) do
    shared =
      Enum.zip(current["messages"], messages)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

    added = messages |> Enum.drop(shared) |> Enum.count(&(&1["role"] == "user"))
    current_turn(current) + added
  end

  defp next_turn(current, _messages, turn_id),
    do: current_turn(current) + if(current["turn_id"] == turn_id, do: 0, else: 1)

  defp current_turn(current),
    do: current["turn"] || max(Enum.count(current["messages"], &(&1["role"] == "user")), 1)

  # Representation migration preserves every public revision and fence. Each
  # archive is atomically replaced only after all its objects are durable.
  defp migrate_archives(id, opts) do
    with {:ok, paths} <- Store.revision_files(id, opts),
         {:ok, :ok} <-
           Alto.Result.reduce(paths, :ok, fn path, :ok ->
             with {:ok, contents} <- Alto.BoundedFile.read(path, @max_entry_bytes),
                  {:ok, record} when is_map(record) <- JSON.decode(contents) do
               if record["v"] == 4 do
                 with {:ok, snapshot} <-
                        entry_snapshot(
                          {:ok, record},
                          id,
                          record["revision"],
                          byte_size(contents),
                          false,
                          opts
                        ),
                      {:ok, plan} <- Store.plan(id, snapshot["messages"], opts),
                      converted <-
                        Map.merge(snapshot, %{
                          "v" => @version,
                          "message_root" => plan.root,
                          "message_count" => plan.count,
                          "turn" => current_turn(snapshot),
                          "turn_id" => nil,
                          "retained_turns" => nil
                        }),
                      {:ok, encoded} <- encode_bounded(converted),
                      :ok <- Store.write(plan),
                      :ok <- DurableLog.replace(path, encoded, mode: 0o600),
                      do: {:ok, :ok}
               else
                 if record["v"] == @version,
                   do: {:ok, :ok},
                   else: {:error, {:conversation_corrupt, id, :migration}}
               end
             else
               {:error, _} = error -> error
               _ -> {:error, {:conversation_corrupt, id, :migration}}
             end
           end),
         do: :ok
  end

  defp current_head(id, opts) do
    case read_head(id, opts, true) do
      {:ok, head, encoded} -> {:ok, head, encoded}
      {:error, :enoent} -> {:ok, nil, nil}
      {:error, _} = error -> error
    end
  end

  defp archive_current(_id, nil, _encoded, _opts), do: :ok

  defp archive_current(id, snapshot, encoded, opts),
    do: put_entry(id, snapshot["revision"], encoded, opts)

  defp resolve_parent(_id, nil, parent), do: {:ok, parent}

  defp resolve_parent(id, current, nil),
    do: {:ok, %{"session_id" => id, "revision" => current["revision"]}}

  defp resolve_parent(_id, current, requested) do
    own = %{"session_id" => current["session_id"], "revision" => current["revision"]}

    if requested == own,
      do: {:ok, own},
      else: {:error, {:conversation_parent_conflict, %{current: own, requested: requested}}}
  end

  defp put_entry(id, revision, encoded, opts) do
    path = entry_path(opts, id, revision)

    with :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true) do
      case Alto.BoundedFile.read(path, @max_entry_bytes) do
        {:ok, ""} ->
          DurableLog.replace(path, encoded, mode: 0o600)

        {:ok, ^encoded} ->
          :ok

        {:ok, _existing} ->
          {:error, {:conversation_revision_conflict, %{session_id: id, revision: revision}}}

        {:error, :enoent} ->
          DurableLog.replace(path, encoded, mode: 0o600)

        {:error, reason} ->
          {:error, {:conversation_write_failed, reason}}
      end
    end
  end

  defp write_head(id, record, opts) do
    with {:ok, encoded} <- encode_bounded(record, @max_head_bytes),
         do: write_encoded_head(id, encoded, opts)
  end

  defp write_encoded_head(id, encoded, opts) do
    path = transcript_path(opts, id)

    with :ok <- Storage.ensure_private_dir(Path.dirname(path), owned: true),
         :ok <- Alto.AtomicFile.write(path, encoded <> "\n", mode: 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:session_write_failed, reason}}
    end
  end

  defp read_head(id, opts, encoded? \\ false) do
    case Alto.BoundedFile.read(transcript_path(opts, id), @max_head_bytes) do
      {:ok, contents} -> decode_head(contents, id, encoded?, opts)
      {:error, :enoent} -> missing_head(id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing_head(id, opts) do
    if File.dir?(conversation_dir(opts, id)),
      do: {:error, {:session_corrupt, id, :transcript}},
      else: {:error, :enoent}
  end

  defp decode_head(contents, id, encoded?, opts) do
    with {:ok, %{"revision" => revision} = record} <- JSON.decode(contents),
         {:ok, ^revision} <- requested_revision(revision),
         {:ok, snapshot, encoded} <- entry_snapshot({:ok, record}, id, revision, nil, true, opts) do
      if encoded?, do: {:ok, snapshot, encoded}, else: {:ok, snapshot}
    else
      _ -> {:error, {:session_corrupt, id, :transcript}}
    end
  end

  defp select_revision(_id, :latest, head, _opts), do: {:ok, head}
  defp select_revision(_id, revision, %{"revision" => revision} = head, _opts), do: {:ok, head}

  defp select_revision(id, revision, _head, opts) do
    case Alto.BoundedFile.read(entry_path(opts, id, revision), @max_entry_bytes) do
      {:ok, contents} ->
        entry_snapshot(JSON.decode(contents), id, revision, byte_size(contents), false, opts)

      {:error, :enoent} ->
        {:error, {:conversation_revision_not_found, id, revision}}

      {:error, reason} ->
        {:error, {:conversation_read_failed, reason}}
    end
  end

  defp entry_snapshot(decoded, id, revision, entry_bytes, encoded?, opts) do
    with {:ok, %{"dispatch" => dispatch} = entry} <- decoded,
         true <- is_nil(entry_bytes) or is_nil(dispatch),
         :ok <- validate_dispatch_fence(dispatch, revision),
         true <- entry["v"] in [4, @version],
         true <- entry["session_id"] == id and entry["revision"] == revision,
         {:ok, entry} <- materialize(entry, id, opts),
         true <- is_list(entry["messages"]),
         true <- is_integer(entry["transcript_bytes"]) and entry["transcript_bytes"] >= 0,
         {:ok, settled} <- validate_messages(entry["messages"], true),
         true <- entry["settled"] == settled,
         retained when is_integer(retained) and retained >= 0 <- entry["retained_bytes_before"],
         {:ok, _parent} <- optional_parent(entry["parent"]),
         {:ok, _summary} <- optional_summary(entry["summary"]),
         {:ok, encoded} <- encode_bounded(Map.put(entry, "dispatch", nil)) do
      snapshot =
        Map.put(entry, "conversation_bytes", retained + (entry_bytes || byte_size(encoded)))

      if encoded?, do: {:ok, snapshot, encoded}, else: {:ok, snapshot}
    else
      _ -> {:error, {:conversation_corrupt, id, revision}}
    end
  end

  defp materialize(%{"v" => 4} = entry, _id, _opts), do: {:ok, entry}

  defp materialize(
         %{
           "v" => 5,
           "message_root" => root,
           "message_count" => count,
           "turn" => turn,
           "turn_id" => turn_id,
           "retained_turns" => retained
         } = entry,
         id,
         opts
       ) do
    with true <- is_integer(turn) and turn > 0,
         {:ok, _} <- turn_id(turn_id),
         true <- is_nil(retained) or (is_integer(retained) and retained > 0),
         {:ok, messages} <- Store.read(id, root, count, opts),
         do: {:ok, Map.put(entry, "messages", messages)}
  end

  defp materialize(_, _, _), do: {:error, :invalid_conversation_manifest}

  defp put_dispatch_fence(id, fence, snapshot, opts) do
    current = snapshot["dispatch"]

    cond do
      current && current["run_id"] not in [nil, fence["run_id"]] && fence["run_id"] != nil ->
        {:error,
         {:conversation_dispatch_conflict,
          %{session_id: id, revision: fence["revision"], current: current}}}

      current && current["tool_call_ids"] == fence["tool_call_ids"] ->
        {:ok, current}

      true ->
        merged =
          if current do
            %{
              fence
              | "tool_call_ids" => Enum.uniq(current["tool_call_ids"] ++ fence["tool_call_ids"]),
                "run_id" => current["run_id"] || fence["run_id"]
            }
          else
            fence
          end

        with {:ok, _ids} <- validate_tool_call_ids(merged["tool_call_ids"]),
             :ok <- write_head(id, Map.put(snapshot, "dispatch", merged), opts),
             do: {:ok, merged}
    end
  end

  defp validate_dispatch_fence(nil, _revision), do: :ok

  defp validate_dispatch_fence(%{"revision" => revision, "tool_call_ids" => ids}, revision) do
    with {:ok, _} <- validate_tool_call_ids(ids), do: :ok
  end

  defp validate_dispatch_fence(_, _), do: {:error, :invalid_dispatch}

  defp resume_safety(%{"dispatch" => fence} = snapshot, allow) when not is_nil(fence) do
    if allow == true or
         (not snapshot["settled"] and
            dispatched_calls_retained?(snapshot["messages"], fence["tool_call_ids"])) do
      :ok
    else
      {:error,
       {:session_unsettled_tool_dispatch,
        %{
          session_id: snapshot["session_id"],
          revision: snapshot["revision"],
          tool_call_ids: fence["tool_call_ids"],
          run_id: fence["run_id"]
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
    MapSet.subset?(MapSet.new(ids), provider_call_ids(messages))
  end

  defp resolve_dispatch_fence(_id, nil, _messages, _settled, _resolved), do: :ok

  defp resolve_dispatch_fence(id, fence, messages, settled, resolved) do
    resolved = MapSet.union(retained_outcome_ids(messages, settled), MapSet.new(resolved))
    unresolved = Enum.reject(fence["tool_call_ids"], &MapSet.member?(resolved, &1))

    if unresolved == [] do
      :ok
    else
      {:error,
       {:conversation_unresolved_dispatch,
        %{session_id: id, revision: fence["revision"], operation_ids: unresolved}}}
    end
  end

  defp retained_outcome_ids(messages, settled) do
    replies =
      for %{"role" => "tool", "tool_call_id" => id} <- messages,
          is_binary(id),
          into: MapSet.new(),
          do: id

    if settled, do: replies, else: MapSet.union(replies, provider_call_ids(messages))
  end

  defp provider_call_ids(messages) do
    for %{"role" => "assistant", "tool_calls" => calls} <- messages,
        is_list(calls),
        %{"id" => id} <- calls,
        is_binary(id),
        into: MapSet.new(),
        do: id
  end

  defp validate_transcript_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: :ok
  defp validate_transcript_bytes(bytes), do: {:error, {:invalid_transcript_bytes, bytes}}

  defp max_conversation_bytes(opts) do
    case Keyword.get(opts, :max_conversation_bytes, @default_max_conversation_bytes) do
      :infinity -> {:ok, :infinity}
      max when is_integer(max) and max > 0 -> {:ok, max}
      max -> {:error, {:invalid_max_conversation_bytes, max}}
    end
  end

  defp retained_turns(opts) do
    case Keyword.get(opts, :conversation_retained_turns, :infinity) do
      :infinity -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:invalid_conversation_retained_turns, other}}
    end
  end

  defp turn_id(nil), do: {:ok, nil}
  defp turn_id(id) when is_binary(id) and byte_size(id) in 1..512, do: {:ok, id}
  defp turn_id(id), do: {:error, {:invalid_conversation_turn_id, id}}

  defp check_conversation_bytes(_id, _total, :infinity, _entry_bytes), do: :ok
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

  defp optional_parent(%{"session_id" => id, "revision" => revision}),
    do: validate_parent(id, revision)

  defp optional_parent(parent), do: {:error, {:invalid_conversation_parent, parent}}

  defp validate_parent(id, revision) do
    with :ok <- Session.validate_id(id),
         true <- is_integer(revision) and revision in 1..@max_revisions do
      {:ok, %{"session_id" => id, "revision" => revision}}
    else
      _ -> {:error, {:invalid_conversation_parent, %{session_id: id, revision: revision}}}
    end
  end

  defp optional_summary(nil), do: {:ok, nil}

  defp optional_summary(summary) when is_binary(summary) do
    if summary != "" and String.valid?(summary) and byte_size(summary) <= @max_summary_bytes,
      do: {:ok, summary},
      else: {:error, {:invalid_branch_summary, byte_size(summary)}}
  end

  defp optional_summary(summary), do: {:error, {:invalid_branch_summary, summary}}

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

  defp encode_bounded(record, max_bytes \\ @max_entry_bytes) do
    record = Map.delete(record, "conversation_bytes")

    record =
      if Map.has_key?(record, "message_root"), do: Map.delete(record, "messages"), else: record

    encoded = JSON.encode!(record)

    if byte_size(encoded) <= max_bytes,
      do: {:ok, encoded},
      else: {:error, {:conversation_too_large, byte_size(encoded), max_bytes}}
  rescue
    error -> {:error, {:session_unencodable, Exception.message(error)}}
  end

  defp transcript_path(opts, id), do: Path.join(Session.dir(opts), id <> ".transcript.json")

  defp entry_path(opts, id, revision) do
    Path.join(conversation_dir(opts, id), "revision-#{revision}.json")
  end

  defp conversation_dir(opts, id), do: Path.join([Session.dir(opts), "conversations", id])
end
