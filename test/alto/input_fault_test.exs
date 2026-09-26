defmodule Alto.InputFaultTest do
  use ExUnit.Case, async: true

  test "input ownership is released without misclassifying scheduler exits" do
    {:ok, input} = Alto.Input.start_link()
    opts = [input: input, loop: Alto.rule_loop(steps: [])]

    assert catch_exit(Alto.Runner.Execution.run(%{}, opts, fn _, _ -> exit(:scheduler_down) end)) ==
             :scheduler_down

    assert {:ok, _reader} = Alto.Input.claim(input)
  end

  test "a dead input channel reports an input failure" do
    {:ok, input} = Alto.Input.start_link()
    GenServer.stop(input)

    assert {:error, {:input_unavailable, _}, _} =
             Alto.Runner.Execution.run(%{}, [input: input], fn _, _ -> flunk("dispatched") end)
  end

  test "owner death releases the channel without dropping queued bytes" do
    {:ok, input} = Alto.Input.start_link(max_messages: 2, max_bytes: 3)
    assert {:ok, %{message_id: id}} = Alto.Messaging.send(input, text: "abc", delivery: :steer)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Alto.Input.claim(input)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, {:ok, old_reader}}
    assert {:error, :not_input_owner} = Alto.Input.read(input, "invalid-token", [:steer])

    assert {:error, :not_input_owner} =
             Alto.Input.acknowledge(input, "invalid-token", id, :consumed)

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert {:ok, reader} = claim_eventually(input)
    assert {:error, :not_input_owner} = Alto.Input.read(input, old_reader, [:steer])

    assert %{message_id: ^id, text: "abc", mode: :steer} =
             Alto.Input.read(input, reader, [:steer])

    assert :ok = Alto.Input.acknowledge(input, reader, id, :consumed)

    # Acknowledgement reclaims the exact encoded byte capacity.
    assert {:ok, _} = Alto.Messaging.send(input, text: "xyz", delivery: :follow_up)
  end

  defp claim_eventually(input, attempts \\ 100)
  defp claim_eventually(_input, 0), do: {:error, :owner_not_released}

  defp claim_eventually(input, attempts) do
    case Alto.Input.claim(input) do
      {:ok, _} = claimed ->
        claimed

      {:error, :input_in_use} ->
        Process.sleep(1)
        claim_eventually(input, attempts - 1)
    end
  end
end
