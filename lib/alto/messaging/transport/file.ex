defmodule Alto.Messaging.Transport.File do
  @moduledoc """
  A private, file-backed polling mailbox using OS locks and atomic replacement.

  Configure `messaging_transport: {__MODULE__, directory: "/private/mailboxes"}`.
  Each agent uses its stable address as the filename. All writers must use this
  protocol on a filesystem with working flock/atomic rename semantics. An OS
  lifetime lock fences the reader; process death releases it without a lease
  timeout. No SSH command or filesystem polling policy is built into the runner.
  """
  @behaviour Alto.Messaging.Transport
  alias Alto.Persistence.Codec
  @limit 20_000_000

  @impl true
  def open(opts) do
    with directory when is_binary(directory) <- opts[:directory],
         id when is_binary(id) <- opts[:id],
         true <- Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, id),
         :ok <- Alto.Storage.ensure_private_dir(directory) do
      handle = %{
        path: Path.join(Path.expand(directory), id <> ".mailbox"),
        bounds: Keyword.take(opts, [:max_messages, :max_bytes])
      }

      with {:ok, _} <- request(handle, :snapshot, 5_000), do: {:ok, handle}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_file_mailbox}
    end
  end

  @impl true
  def request(handle, :claim, timeout) do
    key = {__MODULE__, handle.path}

    if Process.get(key) do
      {:error, :input_in_use}
    else
      with {:ok, lock} <-
             Alto.Storage.acquire(handle.path <> ".reader", timeout: min(timeout, 100)) do
        case transact(handle, :claim, timeout, true) do
          {:ok, _token} = claimed ->
            Process.put(key, lock)
            claimed

          error ->
            Alto.Storage.release(lock)
            error
        end
      end
    end
  end

  def request(handle, :release, timeout) do
    result = transact(handle, :release, timeout)
    if lock = Process.delete({__MODULE__, handle.path}), do: Alto.Storage.release(lock)
    result
  end

  def request(handle, {:take, _} = operation, timeout) do
    reader_path = Path.expand(handle.path <> ".reader")

    case Alto.Storage.with_lock(reader_path, [timeout: min(timeout, 100)], fn ->
           transact(handle, operation, timeout, true)
         end) do
      {:error, {:storage_lock_timeout, ^reader_path, _}} -> {:error, :input_in_use}
      result -> result
    end
  end

  def request(handle, operation, timeout), do: transact(handle, operation, timeout)
  @impl true
  def close(_handle), do: :ok

  defp transact(handle, operation, timeout, reset_owner \\ false) do
    Alto.Storage.with_lock(handle.path <> ".lock", [timeout: timeout], fn ->
      with {:ok, state} <- load(handle) do
        state = if reset_owner, do: %{state | owner: nil}, else: state
        {:reply, reply, next} = Alto.Input.handle_call(operation, {actor(), nil}, state)

        if next == state and File.exists?(handle.path) do
          reply
        else
          with {:ok, encoded} <- Codec.encode(next, max_bytes: @limit),
               :ok <- Alto.AtomicFile.write(handle.path, encoded, mode: 0o600),
               do: reply
        end
      end
    end)
  end

  defp load(handle) do
    case Alto.BoundedFile.read(handle.path, div(@limit * 4, 3) + 8) do
      {:ok, encoded} ->
        with {:ok, %{owner: owner, sealed: sealed} = state} <-
               Codec.decode(encoded, max_bytes: @limit),
             true <- valid_owner?(owner) and is_boolean(sealed),
             true <- Alto.Input.valid_snapshot?(Map.drop(state, [:owner, :sealed])) do
          {:ok, state}
        else
          _ -> {:error, :invalid_file_mailbox}
        end

      {:error, :enoent} ->
        Alto.Input.init(handle.bounds)

      {:error, {:too_large, _, _}} ->
        {:error, :invalid_file_mailbox}

      error ->
        error
    end
  end

  defp valid_owner?(nil), do: true
  defp valid_owner?({actor, token, nil}), do: is_binary(actor) and is_binary(token)
  defp valid_owner?(_), do: false

  defp actor do
    key = {__MODULE__, :actor}

    Process.get(key) ||
      (
        token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        Process.put(key, token)
        token
      )
  end
end
