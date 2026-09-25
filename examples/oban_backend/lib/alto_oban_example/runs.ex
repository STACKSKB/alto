defmodule AltoObanExample.Runs do
  defmodule ProcessEvent do
    @behaviour Alto.Tool

    @impl true
    def name(_opts), do: :process_event

    @impl true
    def schema(_opts), do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode(_opts), do: :exclusive

    @impl true
    def approval(_opts), do: :never

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
