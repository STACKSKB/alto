defmodule Alto.Tools.RunShell do
  @moduledoc "Opt-in Bash command tool using the configured command executor."

  use Alto.Tool,
    name: :run_shell,
    execution_mode: :exclusive,
    approval: :required,
    arguments: true

  alias Alto.Tool.Arguments

  @max_command_bytes 60_000
  @impl true
  def arguments(_opts) do
    {"Run one bounded Bash command string through the harness-configured command executor. Bash starts with errexit and pipefail enabled. Bash errexit has exceptions in conditionals and commands used with && or ||; a script can explicitly change options when nonzero statuses are intentional. Example: {\"command\":\"make test | tail -20\"}.",
     [
       command: [
         type: Arguments.text(1, @max_command_bytes),
         required: true,
         doc: "Complete shell command text, including spaces and pipelines."
       ],
       timeout_ms: [
         type: {:in, 1..120_000},
         default: 30_000,
         doc: "Deadline in milliseconds (1..120000; default 30000)."
       ],
       max_output_bytes: [
         type: {:in, 1..1_000_000},
         default: Alto.Command.default_output_bytes(),
         doc: "Combined stdout/stderr capture limit."
       ]
     ]}
  end

  @impl true
  def prepare(arguments, %{} = context, opts \\ []) do
    command_arguments = %{
      "program" => "bash",
      "args" => ["-e", "-o", "pipefail", "-c", arguments["command"]],
      "timeout_ms" => arguments["timeout_ms"],
      "max_output_bytes" => arguments["max_output_bytes"]
    }

    case Alto.Command.prepare(command_arguments, context, command_options(opts)) do
      {:ok, prepared} -> {:ok, prepared, prepared.approval_details}
      {:error, _} = error -> error
    end
  end

  @impl true
  def run(prepared, %{}, _opts \\ []), do: Alto.Command.execute(prepared)

  defp command_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp command_options(opts), do: opts
end
