defmodule Alto.TestSupport.EchoTool do
  use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :never

  @impl true
  def schema(_opts) do
    %{
      description: "Echo a value.",
      parameters: %{
        type: "object",
        properties: %{value: %{type: "string"}},
        required: ["value"]
      }
    }
  end

  @impl true
  def run(%{"value" => value}, _context, _opts), do: {:ok, %{echo: value}}
end

defmodule Alto.TestSupport.GuardedEchoTool do
  use Alto.Tool, name: :echo, execution_mode: :parallel, approval: :required

  @impl true
  def schema(_opts), do: Alto.TestSupport.EchoTool.schema([])

  @impl true
  def run(arguments, context, opts), do: Alto.TestSupport.EchoTool.run(arguments, context, opts)
end
