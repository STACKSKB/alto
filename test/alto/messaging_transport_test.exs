defmodule Alto.MessagingTransportTest do
  # OS flock subprocess startup is not the behavior under test. Avoid
  # competing with the async suite for a deliberately short lock deadline.
  use ExUnit.Case, async: false
  alias Alto.Input
  alias Alto.Messaging

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

  test "transport open failures are preserved" do
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
    assert {:ok, reader} = Alto.Input.request(channel, :claim)

    assert {:error, :not_input_owner} =
             Task.async(fn -> Alto.Input.request(channel, {:read, "invalid", [:steer]}) end)
             |> Task.await()

    entry =
      Task.async(fn -> Alto.Input.request(channel, {:read, reader, [:steer]}) end) |> Task.await()

    assert entry.message_id == receipt.message_id

    assert {:error, :not_input_owner} =
             Task.async(fn -> Alto.Input.request(channel, :release) end) |> Task.await()

    assert {:error, :invalid_input_operation} =
             Alto.Input.request(channel, {:acknowledge, reader, entry.message_id, :taken})

    {:ok, snapshot} = Alto.Input.request(channel, :snapshot)
    assert {:ok, encoded} = Alto.Persistence.Codec.encode(snapshot)
    {:ok, saved} = Alto.Persistence.Codec.decode(encoded)
    {:ok, restored} = Input.open()
    assert :ok = Alto.Input.request(restored, {:restore, saved})
    assert Alto.Input.request(restored, :list) == [entry]
    assert {:ok, restored_reader} = Alto.Input.request(restored, :claim)

    assert :ok =
             Task.async(fn ->
               Alto.Input.request(
                 restored,
                 {:acknowledge, restored_reader, entry.message_id, :consumed}
               )
             end)
             |> Task.await()

    assert {:ok, %{status: :consumed, message_id: id}} =
             Messaging.send(restored, text: "first", idempotency_key: "key")

    assert id == receipt.message_id

    assert {:error, :idempotency_conflict} =
             Messaging.send(restored, text: "changed", idempotency_key: "key")

    assert :ok = Alto.Input.request(channel, :release)
    assert {:error, :not_input_owner} = Alto.Input.request(channel, {:read, reader, [:steer]})

    assert {:error, :not_input_owner} =
             Alto.Input.request(channel, {:acknowledge, reader, entry.message_id, :consumed})

    Input.close(channel)
  end

  test "checkpoint seals admission, preserves duplicate receipts and respects narrower bounds" do
    {:ok, input} = Input.start_link(max_messages: 5, max_bytes: 100)
    {:ok, receipt} = Messaging.send(input, text: "saved", idempotency_key: "saved")
    {:ok, saved} = Alto.Input.request(input, :checkpoint)
    assert {:error, :input_checkpointed} = Messaging.send(input, text: "too late")
    assert {:ok, ^receipt} = Messaging.send(input, text: "saved", idempotency_key: "saved")
    {:ok, smaller} = Input.start_link(max_messages: 1, max_bytes: 10)
    assert :ok = Alto.Input.request(smaller, {:restore, saved})
    assert {:error, :input_capacity} = Messaging.send(smaller, text: "overflow")

    assert {:error, :invalid_input_snapshot} =
             Alto.Input.request(
               smaller,
               {:restore,
                %{
                  saved
                  | receipts: %{
                      receipt.message_id => %{message_id: receipt.message_id, status: :invalid}
                    }
                }}
             )
  end

  test "restore rejects inconsistent queued receipts and malformed messages without changing input" do
    {:ok, channel} = Input.open()
    {:ok, receipt} = Messaging.send(channel, text: "first")
    {:ok, saved} = Alto.Input.request(channel, :snapshot)
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
      assert {:error, :invalid_input_snapshot} = Alto.Input.request(channel, {:restore, snapshot})
      assert Alto.Input.request(channel, :list) == [entry]
    end
  end

  test "file mailbox shares writes across handles, fences readers and retains newer state", %{
    directory: directory
  } do
    options = [transport: {Alto.Messaging.Transport.File, directory: directory}, id: "agent-one"]
    {:ok, channel} = Input.open(options)
    {:ok, writer} = Input.open(options)
    assert {:ok, reader} = Alto.Input.request(channel, :claim)
    task = Task.async(fn -> Alto.Input.request(writer, :claim) end)
    assert {:error, _} = Task.await(task)
    task = Task.async(fn -> Alto.Input.request(writer, {:take, :any}) end)
    assert {:error, :input_in_use} = Task.await(task)

    {:ok, first} =
      Task.async(fn -> Messaging.send(writer, text: "one", idempotency_key: "one") end)
      |> Task.await()

    {:ok, snapshot} = Alto.Input.request(channel, :snapshot)
    entry = Alto.Input.request(channel, {:read, reader, [:steer]})
    assert :ok = Alto.Input.request(channel, {:acknowledge, reader, entry.message_id, :consumed})
    assert {:ok, second} = Messaging.send(writer, text: "two", idempotency_key: "two")
    assert :ok = Alto.Input.request(channel, :release)
    {:ok, reopened} = Input.open(options)
    assert :ok = Alto.Input.request(reopened, {:restore, snapshot})
    assert [%{message_id: id}] = Alto.Input.request(reopened, :list)
    assert id == second.message_id

    assert {:ok, %{status: :consumed}} =
             Alto.Input.request(reopened, {:receipt, first.message_id})

    assert {:ok, _reader} = Alto.Input.request(reopened, :claim)
    assert :ok = Alto.Input.request(reopened, :release)
    assert {:ok, %{message_id: ^id}} = Alto.Input.request(writer, {:take, :any})
    assert {:ok, _reader} = Alto.Input.request(writer, :claim)
    assert :ok = Alto.Input.request(writer, :release)
  end

  test "file take preserves mailbox lock timeouts and releases its reader lock", %{
    directory: directory
  } do
    {:ok, channel} =
      Input.open(transport: {Alto.Messaging.Transport.File, directory: directory}, id: "take")

    lock_path = channel.handle.path <> ".lock"
    {:ok, lock} = Alto.Storage.acquire(lock_path)

    try do
      assert {:error, {:storage_lock_timeout, ^lock_path, 100}} =
               Input.request(channel, {:take, :any}, 100)
    after
      Alto.Storage.release(lock)
    end

    assert {:ok, _reader} = Input.request(channel, :claim)
    assert :ok = Input.request(channel, :release)
  end

  test "file reader lock recovers after a reader dies", %{directory: directory} do
    {:ok, channel} =
      Input.open(transport: {Alto.Messaging.Transport.File, directory: directory}, id: "crash")

    parent = self()

    pid =
      spawn(fn ->
        {:ok, _reader} = Alto.Input.request(channel, :claim)
        send(parent, :claimed)
        receive do: (:never -> :ok)
      end)

    assert_receive :claimed
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, _reader} = Alto.Input.request(channel, :claim)
    assert :ok = Alto.Input.request(channel, :release)
  end
end
