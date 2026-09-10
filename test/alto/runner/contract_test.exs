defmodule Alto.Runner.ContractTest do
  use ExUnit.Case, async: true
  alias Alto.Runner.{Handle, Result}

  defmodule ExternalRunner do
    @behaviour Alto.Runner
    def run(task, _opts), do: {:ok, %{Result.empty() | output: task, verdict: :completed}}
    def start(task, opts), do: {:ok, {:external_job, task, opts}}
    def await({:external_job, task, opts}, _timeout), do: run(task, opts)
    def cancel(_job, _reason), do: :already_finished
    def terminate(job, _reason), do: await(job, 0)

    def subscribe(job, pid) do
      ref = make_ref()
      send(pid, {:alto_runner_result, ref, await(job, 0)})
      {:ok, ref}
    end
  end

  test "public lifecycle dispatches opaque non-process handles to the selected runner" do
    opts = Alto.Config.new(runner: ExternalRunner) |> Alto.Config.run_options()
    assert {:ok, %Handle{} = handle} = Alto.start("external result", opts)
    assert {:ok, result} = Alto.await(handle)
    assert result.output == "external result"
    assert :already_finished = Alto.cancel(handle)
    assert {:ok, ^result} = Alto.terminate(handle)
    assert {:ok, ref} = Alto.subscribe(handle)
    assert_receive {:alto_runner_result, ^ref, {:ok, ^result}}
    assert :completed = Alto.Consumer.worst_outcome(result)
  end

  test "registry completion does not assume a Task handle or a worker process" do
    name = :"runner_contract_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Alto.FrontEnd.Registry,
       name: name, config_resolver: fn _ -> {:ok, [runner: ExternalRunner]} end}
    )

    assert {:ok, id} = Alto.FrontEnd.Registry.start_run(name, "external", "registry result")

    assert {:ok, {:ok, %Result{output: "registry result"}}} =
             Alto.FrontEnd.Registry.run_result(name, id)

    assert Alto.FrontEnd.Registry.run_ids(name) == []
  end

  test "invalid runner modules fail before starting work" do
    assert {:error, {:invalid_runner, String}} = Alto.start("unused", runner: String)
  end
end
