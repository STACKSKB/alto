defmodule Alto.FrontEnd.RegistryHooksTest do
  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Protocol

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_opts), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), :provider_started)

      receive do
        :release -> {:ok, %{message: "done", tool_calls: []}}
      end
    end
  end

  setup do
    name = :"hooks_registry_#{System.unique_integer([:positive])}"
    test_pid = self()

    resolver = fn
      "fast" -> {:ok, [loop: Alto.rule_loop(steps: [])]}
      "blocking" -> {:ok, [provider: {BlockingProvider, test_pid: test_pid}, max_steps: 1]}
      _ -> {:error, :unused}
    end

    start_supervised!(
      {Registry,
       name: name,
       config_resolver: resolver,
       commands: %{
         "echo" => fn payload ->
           send(test_pid, {:callback_pid, self()})
           {:ok, Map.put(payload, "handled", true)}
         end,
         "reenter" => fn _payload ->
           {:ok, run_id} = Registry.start_run(name, "fast", "from callback")
           {:ok, %{"run_id" => run_id}}
         end,
         "explode" => fn _payload -> raise "boom" end
       }}
    )

    %{name: name}
  end

  test "callbacks run in a supervised task outside the registry and caller", %{name: name} do
    assert {:ok, %{"value" => 1, "handled" => true}} =
             Registry.command(name, "echo", %{"value" => 1})

    assert_receive {:callback_pid, callback_pid}
    refute callback_pid == self()
    refute callback_pid == Process.whereis(name)
    assert {:error, :unknown_command} = Registry.command(name, "missing", %{})
  end

  test "stalled command is terminated and reports an uncertain outcome" do
    parent = self()
    name = :"command_timeout_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry,
       name: name,
       config_resolver: fn _ -> {:error, :unused} end,
       command_timeout: 20,
       commands: %{
         "stall" => fn _ ->
           send(parent, {:command_worker, self()})
           Process.sleep(:infinity)
         end
       }},
      id: name
    )

    assert {:error, {:command_outcome_unknown, :timeout}} = Registry.command(name, "stall", %{})
    assert_receive {:command_worker, worker}
    refute Process.alive?(worker)
    assert {:ok, []} = Registry.runs(name)
  end

  test "a callback can reenter the registry without deadlocking", %{name: name} do
    assert {:ok, %{"run_id" => run_id}} = Registry.command(name, "reenter", %{})

    assert {:error, :invalid_steps,
            %Alto.Runner.Result{
              run_id: ^run_id,
              verdict: :rejected_before_dispatch
            }} =
             eventually_result(name, run_id)
  end

  test "owner death cancels a running run and result is authoritative", %{name: name} do
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:started, Registry.start_run(name, "blocking", "owned", owner: self())})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:started, {:ok, run_id}}
    # Initial module loading can exceed the global receive timeout in a full
    # suite. Establish readiness before exercising owner cancellation.
    assert_receive :provider_started, 2_000
    assert Registry.run_result(name, run_id) == :running
    send(owner, :stop)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    assert {:error, {:cancelled, {:owner_down, :normal}},
            %Alto.Runner.Result{verdict: :rejected_before_dispatch}} =
             eventually_result(name, run_id)
  end

  test "invalid owners and callback exceptions fail closed", %{name: name} do
    assert {:error, {:invalid_owner, :bad}} =
             Registry.start_run(name, "fast", "bad owner", owner: :bad)

    assert {:error, {:command_exception, "boom"}} = Registry.command(name, "explode", %{})
  end

  defp eventually_result(name, run_id, attempts \\ 200)
  defp eventually_result(_name, _run_id, 0), do: :timeout

  defp eventually_result(name, run_id, attempts) do
    case Registry.run_result(name, run_id) do
      :running ->
        Process.sleep(10)
        eventually_result(name, run_id, attempts - 1)

      {:ok, result} ->
        result
    end
  end

  test "command envelopes require a binary name and map payload" do
    assert {:ok, {:command, "c-1", "echo", %{"value" => 1}}} =
             Protocol.decode_command(
               JSON.encode!(%{
                 "v" => 1,
                 "type" => "command",
                 "id" => "c-1",
                 "name" => "echo",
                 "payload" => %{"value" => 1}
               })
             )

    assert {:error, :invalid} =
             Protocol.decode_command(
               JSON.encode!(%{
                 "v" => 1,
                 "type" => "command",
                 "id" => "c-2",
                 "name" => "echo",
                 "payload" => []
               })
             )
  end

  test "ok replies keep envelope correlation fields authoritative" do
    assert {:ok, line} =
             Protocol.ok(
               "c-7",
               %{"id" => "spoof", "type" => "spoof", "v" => 99, "value" => true},
               1_024
             )

    assert %{"id" => "c-7", "type" => "ok", "v" => 1, "value" => true} =
             JSON.decode!(IO.iodata_to_binary(line))
  end
end
