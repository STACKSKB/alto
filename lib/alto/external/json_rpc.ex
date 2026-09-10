defmodule Alto.External.JSONRPC do
  @moduledoc false

  def deadline(:infinity), do: :infinity

  def deadline(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def send(port, payload, max_bytes) do
    data = JSON.encode!(payload) <> "\n"

    cond do
      byte_size(data) > max_bytes -> {:error, {:json_rpc_message_limit, max_bytes}}
      Port.command(port, data, [:nosuspend]) -> :ok
      true -> {:error, :transport_busy}
    end
  rescue
    ArgumentError -> {:error, :transport_closed}
  end
end
