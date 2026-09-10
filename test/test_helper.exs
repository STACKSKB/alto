ExUnit.start()

# Deliberate crash/suspend tests inspect the optional task host, never clients.
defmodule Alto.Test.Runner do
  def worker(%Alto.Runner.Handle{state: state}), do: worker(state)
  def worker(%Alto.Runner.TaskHost.Handle{pid: host}), do: :sys.get_state(host).task.pid
end
