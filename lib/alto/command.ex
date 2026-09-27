defmodule Alto.Command do
  @moduledoc "Compose a command preparation function with its execution backend."

  alias Alto.Command.Executors.Unsandboxed
  alias Alto.Tool.Arguments

  @default_output_bytes 64_000
  @fields [
    program: [
      type: :string,
      required: true,
      doc:
        "Executable name or path only. Do not put arguments here; each args item is one separate argument. For example, run a compiled program as {\"program\":\"./build/test\",\"args\":[]} and make all as {\"program\":\"make\",\"args\":[\"all\"]}."
    ],
    args: [
      type: Arguments.list(:string, 0, 128),
      default: [],
      doc:
        "Each list item is exactly one argument; keep spaces inside that string and do not add shell quote characters. Do not repeat program. A filename with spaces is one item, e.g. {\"program\":\"cat\",\"args\":[\"file name.txt\"]}. Use an empty list when there are no arguments."
    ],
    timeout_ms: [
      type: {:in, 1..120_000},
      default: 30_000,
      doc: "Deadline in milliseconds (1..120000; default 30000)."
    ],
    max_output_bytes: [
      type: {:in, 1..1_000_000},
      default: @default_output_bytes,
      doc: "Combined stdout/stderr capture limit."
    ]
  ]

  @type invocation :: %{
          requested_program: binary(),
          executable: binary(),
          args: [binary()],
          cwd: binary(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer()
        }
  @type prepared :: %{executor: module(), execution: term(), approval_details: map()}

  def default_output_bytes, do: @default_output_bytes

  @doc false
  def arguments do
    {"Run one executable through the harness-configured command executor using an argument vector. `program` is the executable; each `args` item is exactly one argument. Example JSON: {\"program\":\"./build/test\",\"args\":[]} runs that executable directly. This is not a shell: pipes, redirects, globbing, and && are not interpreted. Prefer running tests directly and inspecting their full exit status/output; do not append tail or echo in a way that hides failure. If a pipeline is necessary, select Bash explicitly and use args [\"-o\",\"pipefail\",\"-lc\",\"make test | tail -20\"] so a failing test still produces a failing command. Standard input is closed (EOF) unless the selected shell opens or redirects it.",
     @fields}
  end

  @doc "Validate bounded argv and resolve the executable before approval."
  def resolve(arguments, %{} = context) do
    with {:ok, values} <- Arguments.validate(arguments, @fields),
         %{"program" => program, "args" => args} = values,
         :ok <- validate_argv(program, args),
         executable when is_binary(executable) <- find_executable(program, context.cwd) do
      {:ok,
       %{
         requested_program: program,
         executable: executable,
         args: args,
         cwd: context.cwd,
         timeout_ms: values["timeout_ms"],
         max_output_bytes: values["max_output_bytes"]
       }}
    else
      nil -> {:error, {:executable_not_found, arguments["program"]}}
      {:error, _} = error -> error
    end
  end

  defp find_executable(program, cwd) do
    # Explicit relative paths belong to the task workspace, not the host VM's cwd.
    candidate =
      if Path.type(program) == :relative and length(Path.split(program)) > 1,
        do: Path.expand(program, cwd),
        else: program

    System.find_executable(candidate)
  end

  defp validate_argv(program, args) do
    cond do
      program == "" -> {:error, :program_must_be_nonempty_string}
      String.contains?(program, <<0>>) -> {:error, :program_contains_nul}
      Enum.any?(args, &String.contains?(&1, <<0>>)) -> {:error, :argument_contains_nul}
      IO.iodata_length(args) > 64_000 -> {:error, {:arguments_too_large, 64_000}}
      true -> :ok
    end
  end

  @spec prepare(map(), Alto.Tool.context(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(arguments, %{} = context, opts \\ []) do
    invocation =
      case Keyword.get(opts, :policy, &resolve/2) do
        prepare when is_function(prepare, 2) -> prepare.(arguments, context)
        {module, function, extra} -> apply(module, function, [arguments, context] ++ extra)
        {:error, _} = rejection -> rejection
      end

    {executor, executor_opts} = Keyword.get(opts, :executor, {Unsandboxed, []})

    with {:ok, %{} = invocation} <- invocation,
         {:ok, execution, executor_details} when is_map(executor_details) <-
           executor.prepare(invocation, executor_opts) do
      {:ok,
       %{
         executor: executor,
         execution: execution,
         approval_details: %{command: invocation, execution: executor_details}
       }}
    end
  end

  @spec execute(prepared()) :: {:ok, map()} | {:error, term()}
  def execute(%{executor: executor, execution: execution}), do: executor.execute(execution)

  @doc "Open an already prepared execution for a bounded, retained stdio client."
  def open(%{executor: executor, execution: execution}, opts \\ []) do
    if function_exported?(executor, :open, 2),
      do: executor.open(execution, opts),
      else: {:error, {:executor_stdio_unsupported, executor}}
  end

  @spec run(map(), Alto.Tool.context(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(arguments, %{} = context, opts \\ []) do
    with {:ok, prepared} <- prepare(arguments, context, opts), do: execute(prepared)
  end
end
