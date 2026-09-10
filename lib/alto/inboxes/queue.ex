defmodule Alto.Inboxes.Queue do
  @moduledoc """
  Compatibility adapter from `Alto.Inbox` to the lightweight JSONL queue.

  This remains available for database-free deployments. A separately installed
  Oban adapter can implement `Alto.Inbox` without becoming a core dependency.
  """

  @behaviour Alto.Inbox

  @impl true
  def validate_options(opts) do
    case Keyword.fetch(opts, :queue) do
      {:ok, queue}
      when not is_nil(queue) and (is_atom(queue) or is_pid(queue) or is_tuple(queue)) ->
        :ok

      _other ->
        {:error, :invalid_queue}
    end
  end

  @impl true
  def admit(delivery_key, payload, opts) do
    queue = Keyword.fetch!(opts, :queue)
    Alto.Queue.admit(queue, delivery_key, payload)
  end
end
