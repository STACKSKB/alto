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

  defmodule SubscribedRunner do
    def subscribe(test, subscriber) do
      ref = make_ref()
      send(test, {:subscribed, subscriber, ref})
      {:ok, ref}
    end

    def cancel(test, reason), do: send(test, {:cancel_requested, reason})
    def await(_, _), do: raise("batch must drain its subscription")

    def terminate(test, reason) do
      send(test, :forced_termination)
      {:error, reason}
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
    assert result.verdict == :completed
  end

  test "registry completion does not assume a Task handle or a worker process" do
    name = :"runner_contract_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Alto.FrontEnd.Registry,
       name: name, config_resolver: fn _ -> {:ok, [runner: ExternalRunner]} end}
    )

    assert {:ok, id} =
             Alto.FrontEnd.Registry.request(name, {:start_run, "external", "registry result", []})

    assert {:ok, {:ok, %Result{output: "registry result"}}} =
             Alto.FrontEnd.Registry.request(name, {:run_result, id})

    assert Alto.FrontEnd.Registry.request(name, :run_ids) == []
  end

  test "child batches handle failed starts and opaque handles without consuming unrelated results" do
    specs = Enum.map(["rejected", "one", "two"], &%{id: &1})
    unrelated = make_ref()
    send(self(), {:alto_runner_result, unrelated, :other_batch})

    start = fn
      %{id: "rejected"} -> {:error, :cannot_start}
      %{id: id} -> ExternalRunner.start(id, [])
    end

    assert {:ok,
            [
              {"rejected", {:error, :cannot_start}},
              {"one", {:ok, %Result{output: "one"}}},
              {"two", {:ok, %Result{output: "two"}}}
            ]} =
             Alto.Runner.Agents.batch(specs, 2, start, fn -> :continue end,
               runner: ExternalRunner
             )

    assert_receive {:alto_runner_result, ^unrelated, :other_batch}
  end

  test "batch cancellation drains subscribed results without awaiting the handle again" do
    parent = self()

    task =
      Task.async(fn ->
        check = fn ->
          receive do
            :cancel -> {:cancelled, :operator}
          after
            0 -> :continue
          end
        end

        Alto.Runner.Agents.batch([%{id: "child"}], 1, fn _ -> {:ok, parent} end, check,
          runner: SubscribedRunner
        )
      end)

    assert_receive {:subscribed, scheduler, ref}, 2_000
    send(task.pid, :cancel)
    assert_receive {:cancel_requested, {:cancelled, :operator}}, 2_000
    send(scheduler, {:alto_runner_result, ref, {:ok, :settled}})
    assert {{:cancelled, :operator}, [{"child", {:ok, :settled}}]} = Task.await(task)
    refute_receive :forced_termination
  end

  test "batch owner death kills an unfinished start without dispatching queued children" do
    parent = self()

    start = fn spec ->
      send(parent, {:starting, spec.id, self()})
      receive do: (:never -> {:error, :unused})
    end

    owner =
      spawn(fn ->
        Alto.Runner.Agents.batch([%{id: "active"}, %{id: "queued"}], 1, start, fn -> :continue end)
      end)

    assert_receive {:starting, "active", starter}, 2_000
    monitor = Process.monitor(starter)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^starter, _}, 2_000
    refute_receive {:starting, "queued", _}
  end

  test "invalid runner modules fail before starting work" do
    assert {:error, {:invalid_runner, String}} = Alto.start("unused", runner: String)
  end
end
