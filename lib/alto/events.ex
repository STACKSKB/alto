defmodule Alto.Events do
  @moduledoc "Synchronous ordered event fan-out for host composition. Each observer fails independently."
  def combine(sinks) when is_list(sinks) do
    fn event -> Enum.each(sinks, &Alto.Runner.Execution.Support.notify(&1, event)) end
  end

  @doc "Deliver to the host first, then the application's existing observer. Both provide backpressure."
  def attach(options, host_sink) do
    Keyword.put(options, :event_sink, combine([host_sink, Keyword.get(options, :event_sink)]))
  end
end
