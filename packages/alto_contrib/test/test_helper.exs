ExUnit.start()

defmodule Alto.Test.Runner do
  def worker(%Alto.Runner.Handle{state: state}), do: worker(state)
  def worker(%Alto.Runner.TaskHost.Handle{pid: host}), do: :sys.get_state(host).task.pid
end

defmodule Alto.Test.ResidentTask do
  def await(name, id, status, attempts, interval) do
    result = Alto.Contrib.Resident.Tasks.command(name, "get", %{"id" => id})

    case result do
      {:ok, %{"task" => %{"status" => ^status} = task}} when attempts > 0 ->
        task

      _ when attempts == 0 ->
        ExUnit.Assertions.flunk("#{id} did not become #{status}: #{inspect(result)}")

      _ ->
        Process.sleep(interval)
        await(name, id, status, attempts - 1, interval)
    end
  end
end
