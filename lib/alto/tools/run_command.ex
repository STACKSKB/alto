defmodule Alto.Tools.RunCommand do
  @moduledoc "Opt-in argv command tool using a configurable policy and executor."

  use Alto.Tool, name: :run_command, execution_mode: :exclusive, approval: :required

  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @impl true
  def schema(_opts \\ []) do
    Alto.Tool.object_schema(
      "Run one executable through the harness-configured command executor using an argument vector. Shell syntax is not interpreted unless a shell is explicitly selected as the program.",
      %{
        program: %{type: "string", minLength: 1, description: "Executable name or path."},
        args: %{
          type: "array",
          items: %{type: "string"},
          maxItems: Invocation.max_args(),
          description: "Arguments passed directly to the executable."
        },
        timeout_ms: %{
          type: "integer",
          minimum: 1,
          maximum: Invocation.max_timeout_ms(),
          description: "Deadline in milliseconds."
        },
        max_output_bytes: %{
          type: "integer",
          minimum: 1,
          maximum: Invocation.max_output_bytes(),
          description: "Combined stdout/stderr capture limit."
        }
      },
      ["program"]
    )
  end

  @impl true
  def prepare(arguments, %Context{} = context, opts \\ []) do
    case Alto.Command.prepare(arguments, context, opts) do
      {:ok, prepared} -> {:ok, prepared, prepared.approval_details}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run(prepared, %Context{}, _opts \\ []), do: Alto.Command.execute(prepared)
end
