defmodule Alto.Tools.QueueCancel do
  @moduledoc """
  Blank every `Alto.Queue` record for a key — the cancellation path.

  Cancelling a key with no live record reports success either way: a
  cancellation webhook for a record that was never queued (or was already
  processed and blanked) is a no-op, not a failure, so redeliveries stay
  idempotent. Same local-boundary trust decision as `Alto.Tools.QueuePut`.
  """

  use Alto.Tool, name: :queue_cancel, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Queue

  @impl true
  def arguments(_opts) do
    {"Remove all queued records carrying a dedup key (record cancellation).",
     [key: [type: :string, required: true]]}
  end

  @impl true
  def run(arguments, _context, opts \\ []) do
    queue = Keyword.get(opts, :queue, Alto.Queue)

    case Queue.request(queue, {:cancel, arguments["key"]}) do
      :ok -> {:ok, %{cancelled: true}}
      {:error, :not_found} -> {:ok, %{cancelled: false}}
      {:error, reason} -> {:error, reason}
    end
  end
end
