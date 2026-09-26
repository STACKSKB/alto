defmodule Alto.MessagingTransportTest do
  use ExUnit.Case, async: true
  alias Alto.{Input, Messaging}

  defmodule Custom do
    @behaviour Alto.Messaging.Transport
    def open(opts), do: Input.start_link(opts)
    def request(pid, request, timeout), do: GenServer.call(pid, request, timeout)
    def close(pid), do: Input.close(pid)
  end

  defmodule Unavailable do
    @behaviour Alto.Messaging.Transport
    def open(_opts), do: {:error, :transport_offline}
    def request(_, _, _), do: raise("unopened transport")
    def close(_), do: :ok
  end

  test "transport configuration rejects invalid capabilities and preserves open failures" do
    for spec <- [NonexistentTransport, {Custom, [:invalid]}] do
      normalized = if is_atom(spec), do: {spec, []}, else: spec

      assert {:error, {:invalid_capability, Alto.Messaging.Transport, ^normalized}} =
               Input.open(transport: spec)
    end

    assert {:error, :transport_offline} = Input.open(transport: {Unavailable, []})
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "alto-mailbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "oversized stored mailboxes are rejected before decoding", %{directory: directory} do
    File.mkdir_p!(directory)
    path = Path.join(directory, "oversized.mailbox")

    File.open!(path, [:write, :raw], fn io ->
      {:ok, _} = :file.position(io, 6_000_000)
      :ok = :file.write(io, "x")
    end)

    assert {:error, :invalid_file_mailbox} =
             Input.open(
               transport: {Alto.Messaging.Transport.File, directory: directory},
               id: "oversized"
             )
  end

  test "custom transport supports queue ownership, portable snapshots and deduplication" do
    {:ok, channel} = Input.open(transport: {Custom, []})
    {:ok, receipt} = Messaging.send(channel, text: "first", idempotency_key: "key")
    assert :ok = Input.claim(channel)
    {:ok, reader} = Input.reader(channel)

    assert {:error, :not_input_owner} =
             Task.async(fn -> Input.peek(channel, [:steer]) end) |> Task.await()

    entry = Task.async(fn -> Input.read(channel, reader, [:steer]) end) |> Task.await()
    assert entry.message_id == receipt.message_id
    {:ok, snapshot} = Input.snapshot(channel)
    assert {:ok, encoded} = Alto.Persistence.Codec.encode(snapshot)
    {:ok, saved} = Alto.Persistence.Codec.decode(encoded)
    {:ok, restored} = Input.open()
    assert :ok = Input.restore(restored, saved)
    assert Input.list(restored) == [entry]
    assert :ok = Input.claim(restored)
    assert :ok = Input.ack(restored, entry.message_id)

    assert {:ok, %{status: :consumed, message_id: id}} =
             Messaging.send(restored, text: "first", idempotency_key: "key")

    assert id == receipt.message_id

    assert {:error, :idempotency_conflict} =
             Messaging.send(restored, text: "changed", idempotency_key: "key")

    assert :ok = Input.release(channel)
    assert {:error, :not_input_owner} = Input.read(channel, reader, [:steer])
    Input.close(channel)
  end

  test "checkpoint seals admission, preserves duplicate receipts and respects narrower bounds" do
    {:ok, input} = Input.start_link(max_messages: 5, max_bytes: 100)
    {:ok, receipt} = Messaging.send(input, text: "saved", idempotency_key: "saved")
    {:ok, saved} = Input.checkpoint(input)
    assert {:error, :input_checkpointed} = Messaging.send(input, text: "too late")
    assert {:ok, ^receipt} = Messaging.send(input, text: "saved", idempotency_key: "saved")
    {:ok, smaller} = Input.start_link(max_messages: 1, max_bytes: 10)
    assert :ok = Input.restore(smaller, saved)
    assert {:error, :input_capacity} = Messaging.send(smaller, text: "overflow")

    assert {:error, :invalid_input_snapshot} =
             Input.restore(smaller, %{
               saved
               | receipts: %{
                   receipt.message_id => %{message_id: receipt.message_id, status: :invalid}
                 }
             })
  end

  test "restore rejects inconsistent queued receipts and malformed messages without changing input" do
    {:ok, channel} = Input.open()
    {:ok, receipt} = Messaging.send(channel, text: "first")
    {:ok, saved} = Input.snapshot(channel)
    [entry] = saved.entries

    malformed = [
      %{saved | receipts: %{}},
      put_in(saved.receipts[receipt.message_id].status, :consumed),
      %{saved | entries: [entry, entry], bytes: saved.bytes * 2},
      %{saved | entries: [%{entry | text: <<255, 255, 255, 255, 255>>}]},
      %{saved | entries: [%{entry | sender: %{}}]},
      %{saved | entries: [%{entry | text: ""}], bytes: 0}
    ]

    for snapshot <- malformed do
      assert {:error, :invalid_input_snapshot} = Input.restore(channel, snapshot)
      assert Input.list(channel) == [entry]
    end
  end

  test "file mailbox shares writes across handles, fences readers and retains newer state", %{
    directory: directory
  } do
    options = [transport: {Alto.Messaging.Transport.File, directory: directory}, id: "agent-one"]
    {:ok, channel} = Input.open(options)
    {:ok, writer} = Input.open(options)
    assert :ok = Input.claim(channel)
    task = Task.async(fn -> Input.claim(writer) end)
    assert {:error, _} = Task.await(task)

    {:ok, first} =
      Task.async(fn -> Messaging.send(writer, text: "one", idempotency_key: "one") end)
      |> Task.await()

    {:ok, snapshot} = Input.snapshot(channel)
    entry = Input.peek(channel, [:steer])
    assert :ok = Input.ack(channel, entry.message_id)
    assert {:ok, second} = Messaging.send(writer, text: "two", idempotency_key: "two")
    assert :ok = Input.release(channel)
    {:ok, reopened} = Input.open(options)
    assert :ok = Input.restore(reopened, snapshot)
    assert [%{message_id: id}] = Input.list(reopened)
    assert id == second.message_id
    assert {:ok, %{status: :consumed}} = Input.receipt(reopened, first.message_id)
    assert :ok = Input.claim(reopened)
    assert :ok = Input.release(reopened)
    assert {:ok, %{message_id: ^id}} = Input.take(writer)
  end

  test "file reader lock recovers after a reader dies", %{directory: directory} do
    {:ok, channel} =
      Input.open(transport: {Alto.Messaging.Transport.File, directory: directory}, id: "crash")

    parent = self()

    pid =
      spawn(fn ->
        :ok = Input.claim(channel)
        send(parent, :claimed)
        receive do: (:never -> :ok)
      end)

    assert_receive :claimed
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert :ok = Input.claim(channel)
    assert :ok = Input.release(channel)
  end
end
