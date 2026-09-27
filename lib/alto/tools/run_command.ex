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
  def run(prepared, %{}, _opts \\ []) do
    case Alto.Command.execute(prepared) do
      {:ok, %{exit_status: status} = result} when is_integer(status) and status != 0 ->
        if completed?(result) and repeated_program?(prepared) do
          {:ok,
           Map.put(result, :hint, %{
             code: :repeated_program_argument,
             message:
               "program is already executed; args starts with the same executable. If accidental, omit that first args item. No retry was performed.",
             retry_performed: false
           })}
        else
          {:ok, result}
        end

      result ->
        result
    end
  end

  defp completed?(result) do
    Map.get(result, :termination, :exit) == :exit and Map.get(result, :timed_out, false) == false
  end

  defp repeated_program?(%{
         approval_details: %{
           command: %{requested_program: program, args: [first | _], cwd: cwd}
         }
       })
       when is_binary(program) and is_binary(first) and is_binary(cwd) do
    first == program or
      (explicit_path?(program) and explicit_path?(first) and
         Path.expand(first, cwd) == Path.expand(program, cwd))
  end

  defp repeated_program?(_prepared), do: false

  defp explicit_path?(value), do: String.contains?(value, "/")
end
