defmodule Alto.Contrib.Resident.MailboxRetentionTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Resident.{Config, Mailbox}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "zek-mailbox-retention-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: make_ref()}
  end

  defp config(dir, mailbox) do
    Config.new(
      workspace: dir,
      state_dir: Path.join(dir, "state"),
      profiles: %{"local" => Alto.Config.default()},
      mailbox: mailbox
    )
  end

  defp context(path),
    do: %{
      session_id: "run",
      cwd: "/tmp",
      agent_identity: %{root_run_id: "team", path: path}
    }

  defp send_message(queue, id, recipient) do
    Mailbox.execute(
      context(["worker"]),
      %{
        "action" => "send",
        "id" => id,
        "to" => recipient,
        "body" => String.duplicate("message", 160)
      },
      queue: queue
    )
  end

  test "mailboxes compact automatically and preserve unread messages and active claims", c do
    config = config(c.dir, max_completed: 3, max_log_bytes: 64_000)
    assert config.mailbox[:auto_compact]
    start_supervised!(Mailbox.child(config, c.name))
    q = Mailbox.queue(c.name)
    assert {:ok, %{key: claimed_key}} = send_message(q, "claimed", [])

    assert {:ok, %{messages: [claimed]}} =
             Mailbox.execute(context([]), %{"action" => "receive"}, queue: q)

    assert {:ok, %{key: unread_key}} = send_message(q, "unread", ["absent-worker"])
    {:ok, unread} = Alto.Queue.request(q, {:lookup, unread_key})

    for n <- 1..100 do
      assert {:ok, %{key: key}} = send_message(q, "churn-#{n}", [])
      assert :ok = Alto.Queue.request(q, {:cancel_pending, key})
    end

    file = Path.join(config.state_dir, "queues/team-messages.jsonl")
    assert File.stat!(file).size <= 64_000
    [header | _] = file |> File.read!() |> String.split("\n", trim: true)

    assert %{"v" => 8, "queue" => "team-messages", "state" => encoded_state} =
             JSON.decode!(header)

    assert is_binary(encoded_state)
    assert {:ok, ^claimed} = Alto.Queue.request(q, {:lookup, claimed_key})
    assert {:ok, ^unread} = Alto.Queue.request(q, {:lookup, unread_key})
    stop_supervised!(Mailbox)
    start_supervised!(Mailbox.child(config, c.name))
    assert {:ok, ^claimed} = Alto.Queue.request(q, {:lookup, claimed_key})
    assert {:ok, ^unread} = Alto.Queue.request(q, {:lookup, unread_key})
    assert {:ok, %{duplicate: true}} = send_message(q, "churn-100", [])
    assert {:ok, %{duplicate: false}} = send_message(q, "churn-1", [])
    assert {:ok, %{live_records: 3}} = Mailbox.commands(c.name)["mailbox.compact"].(%{})

    assert {:ok, _} =
             Mailbox.execute(
               context([]),
               %{"action" => "ack", "key" => claimed_key, "claim_id" => claimed.claim_id},
               queue: q
             )
  end

  test "compaction can be disabled and invalid flags are rejected", c do
    config = config(c.dir, auto_compact: false)
    refute config.mailbox[:auto_compact]
    child = Mailbox.child(config, c.name)
    start_supervised!(child)
    refute :sys.get_state(Mailbox.queue(c.name)).auto_compact
    assert_raise ArgumentError, fn -> config(c.dir, auto_compact: :yes) end
  end
end
