defmodule Alto.Tools.QueueCancel do
  @moduledoc """
  Blank every `Alto.Queue` record for a key — the cancellation path.

  Cancelling a key with no live record reports success either way: a
  cancellation webhook for a record that was never queued (or was already
  processed and blanked) is a no-op, not a failure, so redeliveries stay
  idempotent. Same local-boundary trust decision as `Alto.Tools.QueuePut`.
  """

  @behaviour Alto.Tool

  alias Alto.Queue

  @impl true
  def name, do: :queue_cancel

  @impl true
  def schema do
    %{
      description: "Remove all queued records carrying a dedup key (record cancellation).",
      parameters: %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "The dedup key to blank."}
        },
        required: ["key"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def approval, do: :never

  @impl true
  def run(arguments, context), do: run(arguments, context, [])

  @impl true
  def run(arguments, _context, opts) do
    queue = Keyword.get(opts, :queue, Alto.Queue)

    case Map.get(arguments, "key") do
      key when is_binary(key) ->
        case Queue.cancel(queue, key) do
          :ok -> {:ok, %{cancelled: true}}
          {:error, :not_found} -> {:ok, %{cancelled: false}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_key}
    end
  end
end
