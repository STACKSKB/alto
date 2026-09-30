defmodule Alto.Contrib.Tools.QueuePut do
  @moduledoc """
  Idempotently upsert a record into a configured `Alto.Queue`.

  A local durable write, not an external effect: the record is keyed by the
  caller's dedup key (a record id, say), the payload is bounded by the
  queue itself, and the record leaves the queue only by an explicit ack or
  cancel. That is the tool-author trust decision behind `approval: :never`
  (Alto.Tool) — the queue is inside the host boundary, unlike a connector
  that talks to an external system.
  """

  use Alto.Tool, name: :queue_put, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Queue

  @impl true
  def arguments(_opts) do
    {"Idempotently add or update a record in a durable queue, keyed by a dedup key.",
     [key: [type: :string, required: true], payload: [type: {:map, :any, :any}, default: %{}]]}
  end

  @impl true
  def run(arguments, _context, opts \\ []) do
    queue = Keyword.get(opts, :queue, Alto.Queue)

    Queue.request(queue, {:put, arguments["key"], arguments["payload"], []})
  end
end
