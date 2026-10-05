defmodule Alto.Events do
  @moduledoc "Synchronous ordered event fan-out for host composition. Each observer fails independently."
  @doc """
  Run host work with a bounded observer and return `{result, delivery_status}`.

  Host ownership ends after a bounded drain. Inspect the status before reporting
  observer delivery as successful. Use `Observer.open/2` for a longer-lived owner.
  """
  def with_buffered(sink, opts \\ [], work) when is_function(work, 1) do
    {:ok, observer} = Alto.Events.Observer.open(sink, Keyword.delete(opts, :drain_timeout))

    try do
      result = work.(Alto.Events.Observer.sink(observer))
      status = Alto.Events.Observer.close(observer, Keyword.get(opts, :drain_timeout, 5_000))
      {result, status}
    after
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 1_000)
    end
  end

  def combine(sinks) when is_list(sinks) do
    fn event -> Enum.each(sinks, &Alto.Events.notify(&1, event)) end
  end

  @doc "Deliver to the host first, then the application's existing observer. Both provide backpressure."
  def attach(options, host_sink) do
    Keyword.put(options, :event_sink, combine([host_sink, Keyword.get(options, :event_sink)]))
  end

  @doc "Safely notify an observer."
  def notify(sink, event) when is_function(sink, 1) do
    sink.(event)
    :ok
  catch
    _, _ -> :ok
  end

  def notify(_, _), do: :ok
end
