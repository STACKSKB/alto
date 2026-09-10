defmodule Alto.Tools.RunCommand do
  @moduledoc "Opt-in argv command tool using a configurable policy and executor."

  @behaviour Alto.Tool

  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @impl true
  def name, do: :run_command

  @impl true
  def schema do
    %{
      description:
        "Run one executable through the harness-configured command executor using an argument vector. Shell syntax is not interpreted unless a shell is explicitly selected as the program.",
      parameters: %{
        type: "object",
        properties: %{
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
        required: ["program"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :exclusive

  @impl true
  def approval, do: :required

  @impl true
  def prepare(arguments, %Context{} = context), do: prepare(arguments, context, [])

  @impl true
  def prepare(arguments, %Context{} = context, opts) do
    case Alto.Command.prepare(arguments, context, opts) do
      {:ok, prepared} -> {:ok, prepared, prepared.approval_details}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run_prepared(prepared, %Context{}), do: Alto.Command.execute(prepared)

  @impl true
  def run_prepared(prepared, %Context{}, _opts), do: Alto.Command.execute(prepared)

  @impl true
  def run(arguments, %Context{} = context), do: Alto.Command.run(arguments, context)

  @impl true
  def run(arguments, %Context{} = context, opts), do: Alto.Command.run(arguments, context, opts)
end
