defmodule Alto.Tools.RunCommand do
  @moduledoc "Opt-in argv command tool using a configurable policy and executor."

  use Alto.Tool, name: :run_command, execution_mode: :exclusive, approval: :required

  @impl true
  def schema(_opts \\ []), do: Alto.Tool.Arguments.schema(Alto.Command.arguments())

  @impl true
  def prepare(arguments, %{} = context, opts \\ []) do
    case Alto.Command.prepare(arguments, context, opts) do
      {:ok, prepared} -> {:ok, prepared, prepared.approval_details}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run(prepared, %{}, _opts \\ []), do: Alto.Command.execute(prepared)
end
