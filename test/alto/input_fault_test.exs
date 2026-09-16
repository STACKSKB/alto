defmodule Alto.InputFaultTest do
  use ExUnit.Case, async: true

  test "owner death releases the channel without dropping queued bytes" do
    {:ok, input} = Alto.Input.start_link(max_messages: 2, max_bytes: 3)
    assert {:ok, id} = Alto.Input.put(input, "abc", :steer)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Alto.Input.claim(input)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, :ok}
    assert {:error, :not_input_owner} = Alto.Input.peek(input, [:steer])
    assert {:error, :not_input_owner} = Alto.Input.ack(input, id)

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert :ok = claim_eventually(input)

    assert %{id: ^id, text: "abc", mode: :steer} = Alto.Input.peek(input, [:steer])
    assert :ok = Alto.Input.ack(input, id)

    # Acknowledgement reclaims the exact encoded byte capacity.
    assert {:ok, _} = Alto.Input.put(input, "xyz", :follow_up)
  end

  defp claim_eventually(input, attempts \\ 100)
  defp claim_eventually(_input, 0), do: {:error, :owner_not_released}

  defp claim_eventually(input, attempts) do
    case Alto.Input.claim(input) do
      :ok ->
        :ok

      {:error, :input_in_use} ->
        Process.sleep(1)
        claim_eventually(input, attempts - 1)
    end
  end
end
