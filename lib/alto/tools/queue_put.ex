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

  use Alto.Tool, name: :queue_put, execution_mode: :parallel, approval: :never

  alias Alto.Queue

  @impl true
  def schema(_opts \\ []) do
    Alto.Tool.object_schema(
      "Idempotently add or update a record in a durable queue, keyed by a dedup key.",
      %{
        key: %{type: "string", description: "Dedup key, e.g. the record id."},
        payload: %{type: "object", description: "The record payload."}
      },
      ["key"]
    )
  end

  @impl true
  def run(arguments, _context, opts \\ []) do
    queue = Keyword.get(opts, :queue, Alto.Queue)

    case Map.get(arguments, "key") do
      key when is_binary(key) ->
        Queue.put(queue, key, Map.get(arguments, "payload", %{}))

      _other ->
        {:error, :invalid_key}
    end
  end
end
