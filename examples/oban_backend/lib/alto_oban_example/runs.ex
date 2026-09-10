defmodule AltoObanExample.Runs do
  defmodule ProcessEvent do
    @behaviour Alto.Tool

    @impl true
    def name, do: :process_event

    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode, do: :exclusive

    @impl true
    def approval, do: :never

    @impl true
    def run(arguments, context), do: run(arguments, context, [])

    @impl true
    def run(arguments, _context, _opts) do
      IO.puts("processed event by Oban: #{inspect(arguments)}")
      {:ok, arguments}
    end
  end

  def fetch("event_flow") do
    {:ok,
     [
       loop: Alto.rule_loop(steps: ["process_event"]),
       tools: [ProcessEvent]
     ]}
  end

  def fetch(other), do: {:error, {:unknown_run, other}}
end
