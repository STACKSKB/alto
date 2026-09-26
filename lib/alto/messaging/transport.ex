defmodule Alto.Messaging.Transport do
  @moduledoc """
  Host-selected mailbox transport. The default is an `Alto.Input` process.

  Implement `open/1`, `request/3` and `close/1` to use SSH, a database or another
  channel. Requests are the operations in `Alto.Input`: enqueue, duplicate,
  receipt, pending, claim/release, reader, peek/ack, list/take, checkpoint,
  snapshot/restore and external delivery settlement.
  Operations must be atomic, bounded, ordered per mailbox and preserve message
  IDs and idempotency keys. Only the claimed reader (or its opaque reader token)
  may acknowledge input. `:delivered` means an external adapter accepted input;
  `:unknown` means delivery may have happened and must not be retried automatically.

  Snapshots contain portable data, never connections or credentials. Restore must
  reject conflicting state and preserve newer writes to the same durable mailbox.
  Transport implementations are trusted host configuration, never model arguments
  or executable modules read from a checkpoint. Timeouts are milliseconds.
  """
  defmodule Channel do
    @moduledoc false
    @enforce_keys [:module, :handle]
    defstruct [:module, :handle]
  end

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback request(term(), term(), timeout()) :: term()
  @callback close(term()) :: term()

  def open(opts \\ []) do
    case Keyword.pop(opts, :transport) do
      {nil, opts} ->
        Alto.Input.start_link(opts)

      {transport, opts} ->
        with {:ok, {module, config}} <- Alto.Capabilities.resolve(transport, __MODULE__),
             {:ok, handle} <- module.open(Keyword.merge(config, opts)),
             do: {:ok, %Channel{module: module, handle: handle}}
    end
  end
end
