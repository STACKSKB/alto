defmodule Alto.MessagingTest do
  use ExUnit.Case, async: true

  test "routing authenticates senders, separates instances, bounds queues, and retains receipts" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, input} = Alto.Input.start_link(max_messages: 1)
    {:ok, a} = Alto.Messaging.register(router, label: "worker", input: input)
    {:ok, b} = Alto.Messaging.register(router, label: "worker")
    {:ok, other} = Alto.Messaging.start_link()
    {:ok, outsider} = Alto.Messaging.register(other)
    refute a.id == b.id
    assert {:error, :unknown_agent} = Alto.Messaging.send(outsider, a.id, text: "outside")

    assert {:error, :invalid_sender} =
             Alto.Messaging.send(%{b | token: make_ref()}, a.id, text: "forged")

    assert {:ok, %{message_id: id, status: :queued}} =
             Alto.Messaging.send(b, a.id, text: "hello", idempotency_key: "one")

    assert {:ok, %{message_id: ^id}} =
             Alto.Messaging.send(b, a.id, text: "hello", idempotency_key: "one")

    assert {:error, :idempotency_conflict} =
             Alto.Messaging.send(b, a.id, text: "changed", idempotency_key: "one")

    assert {:error, :input_capacity} = Alto.Messaging.send(b, a.id, text: "full")
    assert [%{sender: %{kind: :agent, id: sender_id}, message_id: ^id}] = Alto.Input.list(input)
    assert sender_id == b.id
    assert {:ok, ^input} = Alto.Messaging.bind(a)
    assert :ok = Alto.Input.claim(input)
    entry = Alto.Input.peek(input, [:steer])
    assert :ok = Alto.Input.ack(input, entry.message_id)
    assert :ok = Alto.Messaging.close(a)
    assert {:ok, %{status: :consumed}} = Alto.Input.receipt(input, id)

    assert {:ok, %{message_id: ^id, status: :consumed}} =
             Alto.Messaging.send(b, a.id, text: "hello", idempotency_key: "one")

    assert {:error, :recipient_closed} = Alto.Messaging.send(b, a.id, text: "late")
  end

  test "user ingress rejects invalid metadata and external backends reject delivery" do
    {:ok, input} = Alto.Input.start_link(max_bytes: 4)
    assert {:error, :invalid_message} = Alto.Messaging.send(input, text: "x", sender: "agent")

    assert {:error, :invalid_message} =
             Alto.Messaging.send(input, text: "x", delivery: :interrupt)

    assert {:error, :input_capacity} = Alto.Messaging.send(input, text: "12345")
    assert {:ok, _} = Alto.Messaging.send(input, text: "1234", delivery: :follow_up)
    assert [%{sender: %{kind: :user}, mode: :follow_up}] = Alto.Input.list(input)
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, external} = Alto.Messaging.register(router, supported: false)
    assert {:error, :messaging_unsupported} = Alto.Messaging.send(router, external.id, text: "x")
  end

  test "recipient exit closes routing while accepted input remains inspectable" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, input} = Alto.Input.start_link()
    {:ok, agent} = Alto.Messaging.register(router, input: input)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, _} = Alto.Messaging.bind(agent)
        send(parent, :bound)
        receive do: (:finish -> :ok)
      end)

    assert_receive :bound
    assert {:ok, _} = Alto.Messaging.send(router, agent.id, text: "accepted")
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    eventually(fn ->
      assert {:error, :recipient_closed} = Alto.Messaging.send(router, agent.id, text: "late")
    end)

    assert Enum.any?(Alto.Input.list(input), &(&1.text == "accepted"))
  end

  test "idle host retries select user submissions without promoting peer context" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, input} = Alto.Input.start_link()
    {:ok, a} = Alto.Messaging.register(router, input: input)
    {:ok, b} = Alto.Messaging.register(router)
    {:ok, _} = Alto.Messaging.send(b, a.id, text: "peer context")
    {:ok, _} = Alto.Messaging.send(input, text: "user task")
    assert {:ok, %{text: "user task", sender: %{kind: :user}}} = Alto.Input.take(input, :user)
    assert [%{text: "peer context", sender: %{kind: :agent}}] = Alto.Input.list(input)
  end

  defp eventually(fun, attempts \\ 100) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(2)
      eventually(fun, attempts - 1)
  end
end
