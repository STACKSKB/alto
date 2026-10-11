defmodule Alto.Contrib.Resident.MailboxTest do
  use ExUnit.Case, async: true
  alias Alto.Queue
  alias Alto.Contrib.Resident.Mailbox

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-mailbox-#{System.unique_integer([:positive])}")
    clock = start_supervised!({Agent, fn -> 1_000 end})

    service_name = make_ref()

    opts = [
      id: "messages",
      dir: dir,
      name: Mailbox.queue(service_name),
      lease_ms: 100,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    queue = start_supervised!({Queue, opts})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{queue: queue, clock: clock, opts: opts, service_name: service_name}
  end

  defp context(root, path) do
    %{
      cwd: System.tmp_dir!(),
      session_id: "current-run",
      agent_identity: %{root_run_id: root, path: path}
    }
  end

  defp call(queue, context, args), do: Mailbox.execute(context, args, queue: queue)

  defp send_args(id, to, body \\ "finding"),
    do: %{"action" => "send", "id" => id, "to" => to, "body" => body}

  test "operator inspection is scoped and cancellation refuses live claims", %{
    queue: q,
    service_name: name
  } do
    sender = context("team", ["a"])
    assert {:ok, %{key: key}} = call(q, sender, send_args("one", []))
    commands = Mailbox.commands(name)
    assert {:ok, %{messages: [_]}} = commands["mailbox.list"].(%{"root" => "team"})
    assert {:ok, %{messages: []}} = commands["mailbox.list"].(%{"root" => "other"})

    assert {:error, :invalid_mailbox_query} =
             commands["mailbox.get"].(%{"root" => "other", "key" => key})

    assert {:ok, %{message: message}} =
             commands["mailbox.get"].(%{"root" => "team", "key" => key})

    assert message.payload["body"] == "finding"
    assert {:ok, %{messages: [claimed]}} = call(q, context("team", []), %{"action" => "receive"})

    assert {:error, {:key_claimed, ^key}} =
             commands["mailbox.cancel"].(%{"root" => "team", "key" => key})

    assert {:ok, _} =
             call(q, context("team", []), %{
               "action" => "release",
               "key" => key,
               "claim_id" => claimed.claim_id
             })

    assert {:ok, %{status: "cancelled"}} =
             commands["mailbox.cancel"].(%{"root" => "team", "key" => key})

    assert {:ok, %{duplicate: true}} = call(q, sender, send_args("one", []))
  end

  test "routing and receipt settlement cannot cross recipient or execution-tree boundaries", %{
    queue: q
  } do
    a = context("team", ["a"])
    b = context("team", ["b"])
    stranger = context("another-team", ["b"])
    assert {:ok, %{duplicate: false}} = call(q, a, send_args("finding", ["b"]))
    assert {:ok, %{messages: []}} = call(q, a, %{"action" => "receive"})
    assert {:ok, %{messages: []}} = call(q, stranger, %{"action" => "receive"})
    assert {:ok, %{messages: [message]}} = call(q, b, %{"action" => "receive"})
    assert message.payload["from"] == ["a"]
    ack = %{"action" => "ack", "key" => message.key, "claim_id" => message.claim_id}
    assert {:error, :mailbox_claim_mismatch} = call(q, a, ack)
    assert {:error, :mailbox_claim_mismatch} = call(q, stranger, ack)
    assert {:ok, _} = call(q, b, ack)
    assert %{pending: 0, claimed: 0} = Queue.request(q, :count)
  end

  test "first-wins identity survives claim, ack and restart", %{queue: q, opts: opts} do
    sender = context("team", ["a"])
    lead = context("team", [])
    assert {:ok, %{key: key}} = call(q, sender, send_args("result", [], "original"))

    assert {:ok, %{duplicate: true, key: ^key}} =
             call(q, sender, send_args("result", ["b"], "changed"))

    assert {:ok, %{messages: [message]}} = call(q, lead, %{"action" => "receive"})
    assert message.payload["body"] == "original"
    assert {:ok, %{duplicate: true}} = call(q, sender, send_args("result", []))

    assert {:ok, _} =
             call(q, lead, %{"action" => "ack", "key" => key, "claim_id" => message.claim_id})

    stop_supervised!(Queue)
    recovered = start_supervised!({Queue, opts})
    assert {:ok, %{duplicate: true}} = call(recovered, sender, send_args("result", []))
    assert {:ok, %{messages: []}} = call(recovered, lead, %{"action" => "receive"})
    # An execution in the same session starts a distinct message namespace.
    assert {:ok, %{duplicate: false}} =
             call(recovered, context("new-team", ["a"]), send_args("result", []))
  end

  test "expired and released leases redeliver with new fenced claim ids", %{
    queue: q,
    clock: clock
  } do
    lead = context("team", [])
    assert {:ok, _} = call(q, context("team", ["a"]), send_args("one", []))
    assert {:ok, %{messages: [first]}} = call(q, lead, %{"action" => "receive"})
    Agent.update(clock, fn _ -> 1_101 end)
    assert {:ok, %{messages: [second]}} = call(q, lead, %{"action" => "receive"})
    assert first.claim_id != second.claim_id

    assert {:error, :mailbox_claim_mismatch} =
             call(q, lead, %{"action" => "ack", "key" => first.key, "claim_id" => first.claim_id})

    assert {:ok, _} =
             call(q, lead, %{
               "action" => "release",
               "key" => second.key,
               "claim_id" => second.claim_id
             })

    assert {:ok, %{messages: [third]}} = call(q, lead, %{"action" => "receive"})
    assert third.claim_id != second.claim_id
  end

  test "forged identities, invalid envelopes and undeliverable encodings are rejected before admission",
       %{queue: q} do
    ctx = context("team", [])

    for args <- [
          Map.put(send_args("x", []), "from", ["victim"]),
          Map.put(send_args("x", []), "root", "victim"),
          send_args("x", "lead"),
          send_args("x", List.duplicate("a", 17)),
          send_args("x", [], <<255>>),
          %{"action" => "receive", "count" => 11},
          %{"action" => "receive", "to" => ["victim"]}
        ] do
      assert {:error, _} = call(q, ctx, args)
    end

    assert {:error, :message_too_large} =
             call(q, ctx, send_args("x", [], String.duplicate("\u0001", 6_000)))

    assert {:error, :mailbox_identity_required} =
             call(q, %{ctx | agent_identity: nil}, send_args("x", []))

    assert %{pending: 0, claimed: 0} = Queue.request(q, :count)
  end

  test "bounded receive returns a deliverable prefix without leasing unseen messages", %{queue: q} do
    ctx = context("team", [])

    for id <- 1..3,
        do:
          assert(
            {:ok, _} = call(q, ctx, send_args(to_string(id), [], String.duplicate("x", 25_000)))
          )

    assert {:ok, %{messages: [message]} = received} = call(q, ctx, %{"action" => "receive"})
    assert message.payload["id"] == "1"
    assert byte_size(JSON.encode!(Alto.TermProjection.encode_term(received))) < 64_000
    assert %{pending: 2, claimed: 1} = Queue.request(q, :count)
  end
end
