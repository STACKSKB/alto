defmodule Alto.Approvals.Interactive do
  @moduledoc "Line-oriented per-invocation approval for the CLI."

  @behaviour Alto.Approval

  @impl true
  def decide(request, context, opts) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stderr)

    IO.write(output, """

    Approval required
      tool: #{request.tool}
      cwd:  #{context.cwd}
      arguments: #{inspect(request.arguments, pretty: true, limit: 20, printable_limit: 2_000)}
    #{format_details(request.details)}
    """)

    case IO.gets(input, "Approve this invocation? [y/N] ") do
      answer when is_binary(answer) ->
        if String.downcase(String.trim(answer)) in ["y", "yes"] do
          :approve
        else
          {:deny, :user_denied}
        end

      :eof ->
        {:deny, :input_closed}

      {:error, reason} ->
        {:deny, {:input_error, reason}}
    end
  end

  defp format_details(details) when details == %{}, do: ""

  defp format_details(details) do
    "  prepared: " <> inspect(details, pretty: true, limit: 50, printable_limit: 4_000)
  end
end
