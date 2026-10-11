defmodule Alto.Contrib.Tools.RunShell do
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
       ]
     ] ++
       Keyword.take(elem(Alto.Contrib.Command.arguments(), 1), [:timeout_ms, :max_output_bytes])}
  end

  @impl true
  def prepare(arguments, %{} = context, opts \\ []) do
    command_arguments = %{
      "program" => "bash",
      "args" => ["-e", "-o", "pipefail", "-c", arguments["command"]],
      "timeout_ms" => arguments["timeout_ms"],
      "max_output_bytes" => arguments["max_output_bytes"]
    }

    Alto.Contrib.Tools.RunCommand.prepare(command_arguments, context, Enum.to_list(opts))
  end

  @impl true
  def run(prepared, %{}, _opts \\ []), do: Alto.Contrib.Command.execute(prepared)
end
