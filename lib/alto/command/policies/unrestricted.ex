defmodule Alto.Command.Policies.Unrestricted do
  @moduledoc "Validate and resolve any bounded argv request without restricting the program."

  @behaviour Alto.Command.Policy

  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @impl true
  def prepare(arguments, %Context{} = context, _opts) do
    program = Map.get(arguments, "program")
    args = Map.get(arguments, "args", [])
    timeout_ms = Map.get(arguments, "timeout_ms", Invocation.default_timeout_ms())

    max_output_bytes =
      Map.get(arguments, "max_output_bytes", Invocation.default_output_bytes())

    with :ok <- validate_program(program),
         :ok <- validate_args(args),
         :ok <- validate_limit(:timeout_ms, timeout_ms, Invocation.max_timeout_ms()),
         :ok <-
           validate_limit(
             :max_output_bytes,
             max_output_bytes,
             Invocation.max_output_bytes()
           ),
         executable when is_binary(executable) <- System.find_executable(program) do
      {:ok,
       %Invocation{
         requested_program: program,
         executable: executable,
         args: args,
         cwd: context.cwd,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes
       }}
    else
      nil -> {:error, {:executable_not_found, program}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_program(program) when is_binary(program) and program != "" do
    if String.contains?(program, <<0>>), do: {:error, :program_contains_nul}, else: :ok
  end

  defp validate_program(_program), do: {:error, :program_must_be_nonempty_string}

  defp validate_args(args) when is_list(args) do
    cond do
      length(args) > Invocation.max_args() ->
        {:error, {:too_many_arguments, Invocation.max_args()}}

      not Enum.all?(args, &is_binary/1) ->
        {:error, :arguments_must_be_strings}

      Enum.any?(args, &String.contains?(&1, <<0>>)) ->
        {:error, :argument_contains_nul}

      Enum.sum(Enum.map(args, &byte_size/1)) > Invocation.max_argument_bytes() ->
        {:error, {:arguments_too_large, Invocation.max_argument_bytes()}}

      true ->
        :ok
    end
  end

  defp validate_args(_args), do: {:error, :arguments_must_be_list}

  defp validate_limit(_name, value, maximum)
       when is_integer(value) and value > 0 and value <= maximum,
       do: :ok

  defp validate_limit(name, value, maximum),
    do: {:error, {:invalid_limit, name, value, maximum}}
end
