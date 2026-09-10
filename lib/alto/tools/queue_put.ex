defmodule Alto.Tools.QueuePut do
  @moduledoc """
  Idempotently upsert a record into a configured `Alto.Queue`.

  A local durable write, not an external effect: the record is keyed by the
  caller's dedup key (a record id, say), the payload is bounded by the
  queue itself, and the record leaves the queue only by an explicit ack or
  cancel. That is the tool-author trust decision behind `approval: :never`
  (Alto.Tool) — the queue is inside the host boundary, unlike a connector
  that talks to an external system.
  """

  @behaviour Alto.Tool

  alias Alto.Queue

  @impl true
  def name, do: :queue_put

  @impl true
  def schema do
    %{
      description:
        "Idempotently add or update a record in a durable queue, keyed by a dedup key.",
      parameters: %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "Dedup key, e.g. the record id."},
          payload: %{type: "object", description: "The record payload."}
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
        Queue.put(queue, key, Map.get(arguments, "payload", %{}))

      _other ->
        {:error, :invalid_key}
    end
  end
end
