defmodule Alto.Session.Writer do
  @moduledoc false
  use GenServer

  # Reuse the descriptor/OS lock for short bursts, not for the run's lifetime.
  # Every acknowledged line is fsynced. Release after 2ms idle or 20ms of work
  # so other VMs and transcript transactions can acquire the same session lock.
  def append(id, line, opts) do
    dir = Alto.Session.dir(opts) |> Path.expand()
    key = {dir, id}

    if Process.whereis(Alto.Session.WriterSupervisor) do
      request(key, line, true)
    else
      :unavailable
    end
  catch
    :exit, reason -> {:error, {:session_write_failed, {:writer_stopped, reason}}}
  end

  defp request(key, line, retry?) do
    with {:ok, pid} <- writer(key), do: GenServer.call(pid, {:append, line}, :infinity)
  catch
    :exit, {reason, {GenServer, :call, _}} when retry? and reason in [:normal, :noproc] ->
      request(key, line, false)
  end

  defp writer(key) do
    case Registry.lookup(Alto.Session.WriterRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(Alto.Session.WriterSupervisor, {__MODULE__, key}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, :max_children} -> :unavailable
          {:error, reason} -> {:error, {:session_write_failed, reason}}
        end
    end
  end

  def start_link(key),
    do:
      GenServer.start_link(__MODULE__, key,
        name: {:via, Registry, {Alto.Session.WriterRegistry, key}}
      )

  def child_spec(key),
    do: %{id: key, start: {__MODULE__, :start_link, [key]}, restart: :temporary}

  @impl true
  def init({dir, id}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       path: Path.join(dir, id <> ".jsonl"),
       lock_path: Path.join(dir, id <> ".lock"),
       lock: nil,
       file: nil,
       opened: nil,
       token: nil
     }}
  end

  @impl true
  def handle_call({:append, line}, _, state) do
    state = if state.opened && now() - state.opened >= 20, do: release(state), else: state

    case acquire(state) do
      {:ok, state} ->
        result = with :ok <- :file.write(state.file, line), do: :file.sync(state.file)

        case result do
          :ok ->
            token = make_ref()
            Process.send_after(self(), {:release, token}, 2)
            {:reply, :ok, %{state | token: token}}

          {:error, reason} ->
            {:reply, {:error, {:session_write_failed, reason}}, release(state), 1000}
        end

      {:error, reason} ->
        {:reply, {:error, {:session_write_failed, reason}}, state, 1000}
    end
  end

  @impl true
  def handle_info({:EXIT, lock, reason}, %{lock: lock} = state) when is_port(lock),
    do: {:stop, {:session_lock_lost, reason}, state}

  def handle_info({:release, token}, %{token: token} = state),
    do: {:noreply, release(state), 1000}

  def handle_info({:release, _}, state),
    do: {:noreply, state, if(state.lock, do: :infinity, else: 1000)}

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info(_, state),
    do: {:noreply, state, if(state.lock, do: :infinity, else: 1000)}

  defp acquire(%{lock: lock} = state) when not is_nil(lock) do
    if Port.info(lock) == nil, do: acquire(release(state)), else: {:ok, state}
  end

  defp acquire(state) do
    with {:ok, lock} <- Alto.Storage.acquire(state.lock_path) do
      existed? = File.exists?(state.path)

      result =
        with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(state.path), owned: true),
             :ok <- Alto.Storage.ensure_private_file(state.path),
             {:ok, file} <- :file.open(String.to_charlist(state.path), [:append, :binary, :raw]) do
          case if(existed?,
                 do: :ok,
                 else: Alto.AtomicFile.sync_directory(Path.dirname(state.path))
               ) do
            :ok ->
              {:ok, %{state | lock: lock, file: file, opened: now()}}

            error ->
              :file.close(file)
              error
          end
        end

      case result do
        {:ok, _} = ok ->
          ok

        error ->
          Alto.Storage.release(lock)
          error
      end
    end
  end

  defp release(%{lock: nil} = state), do: state

  defp release(state) do
    :file.close(state.file)
    Alto.Storage.release(state.lock)
    %{state | lock: nil, file: nil, opened: nil, token: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
  @impl true
  def terminate(_, state), do: release(state)
end
