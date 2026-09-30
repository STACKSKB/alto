# Offline synthetic continuation probe. No providers or saved user sessions.
alias Alto.{OperationLog, Subagents.Continuation, Persistence.Codec}
dir = Path.join(System.tmp_dir!(), "alto-redundancy-#{System.unique_integer([:positive])}")

try do
  {:ok, ledger} = OperationLog.start_link(id: "bench", dir: dir)

  ids = Enum.map(1..8, &"child-#{&1}")
  {:ok, batch} = Continuation.open(ledger, "batch", ids)

  tickets =
    Enum.map(ids, fn id ->
      {:ok, ticket} = Continuation.dispatch(batch, id)
      ticket
    end)

  Enum.each(tickets, fn ticket ->
    {:ok, _} =
      Continuation.suspend(ticket, %{"state" => ticket.id <> String.duplicate("x", 32_768)})
  end)

  [path] = Path.wildcard(Path.join(dir, "*.jsonl"))

  commands =
    File.stream!(path)
    |> Enum.map(fn line ->
      {:ok, command} = Codec.decode(JSON.decode!(line), max_bytes: 2_000_000)
      command
    end)

  updates =
    Enum.filter(
      commands,
      &(is_tuple(&1) and elem(&1, 0) in [:checkpoint_update, :checkpoint_delta])
    )

  count = fn recur, term, body ->
    cond do
      is_binary(term) -> if term == body, do: 1, else: 0
      is_tuple(term) -> recur.(recur, Tuple.to_list(term), body)
      is_map(term) -> recur.(recur, Map.to_list(term), body)
      is_list(term) -> Enum.reduce(term, 0, fn value, n -> n + recur.(recur, value, body) end)
      true -> 0
    end
  end

  occurrences =
    Enum.reduce(ids, 0, fn id, total ->
      body = id <> String.duplicate("x", 32_768)
      total + Enum.reduce(commands, 0, fn command, n -> n + count.(count, command, body) end)
    end)

  ledger_result = %{
    children: length(ids),
    unique_checkpoint_bytes: 8 * (32_768 + 7),
    serialized_checkpoint_occurrences: occurrences,
    update_records: length(updates),
    log_bytes: File.stat!(path).size
  }

  event =
    Alto.Event.durable(:model_completed, %{
      message: String.duplicate("text", 8192),
      result: {:ok, 1}
    })

  current = Alto.Session.event_record("run", event)

  legacy =
    current
    |> Map.put("data", Alto.Session.encode_term(event.data))
    |> Map.put("wire_data", Alto.TermProjection.encode_term(event.data))

  event_result = %{
    legacy_bytes: byte_size(JSON.encode!(legacy)),
    current_bytes: byte_size(JSON.encode!(current))
  }

  {:ok, account} =
    Alto.Runner.Budget.Account.open(ledger, "checkpoint-budget",
      max_effects: 100,
      max_model_requests: 20
    )

  sessions = Path.join(dir, "sessions")
  {:ok, id} = Alto.Session.create("checkpoint benchmark", %{}, session_dir: sessions)

  {:ok, run} =
    Alto.Runner.Execution.Setup.open(String.duplicate("context", 300_000),
      max_transcript_bytes: 3_000_000,
      continuation_store: ledger,
      budget_account: account,
      max_effects: 100,
      max_model_requests: 20,
      checkpoint_version: "bench",
      run_timeout: 60_000
    )

  messages = [%{"role" => "user", "content" => String.duplicate("context", 300_000)}]

  run = %{
    run
    | session: id,
      session_dir: sessions,
      messages_rev: messages,
      transcript_bytes: Alto.Context.Transcript.bytes(messages),
      loop_state: %Alto.Loops.Default{task: "synthetic", phase: :awaiting_model}
  }

  {:ok, _} =
    Alto.Session.persist_settled(id, Enum.reverse(run.messages_rev), run.transcript_bytes,
      session_dir: sessions
    )

  {:ok, packet} = Alto.Runner.Checkpoint.capture_parent(run, %{kind: :frame}, [], :continue)
  {:ok, saved} = Alto.Runner.Checkpoint.decode(packet["state"])
  inline = put_in(saved, [:run, :messages_rev], run.messages_rev)

  {:ok, restored, _} =
    Alto.Runner.Checkpoint.restore_parent(run, packet,
      budget_account: account,
      max_effects: 100,
      max_model_requests: 20,
      run_timeout: 60_000
    )

  true = restored.messages_rev == run.messages_rev

  checkpoint_result = %{
    context_bytes: run.transcript_bytes,
    referenced_packet_bytes: :erlang.external_size(packet),
    legacy_inline_state_bytes: :erlang.external_size(inline),
    exact_restore: true
  }

  IO.puts(
    JSON.encode!(%{
      continuation: ledger_result,
      event: event_result,
      checkpoint: checkpoint_result
    })
  )

  GenServer.stop(ledger)
after
  File.rm_rf!(dir)
end
