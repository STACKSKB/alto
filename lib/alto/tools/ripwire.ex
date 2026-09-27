defmodule Alto.Tools.Ripwire do
  @moduledoc """
  Bounded adapter for the external Ripwire CLI.

  Ripwire remains an independently installed executable. Alto contributes only
  a small, stable action schema and runs the selected read-only analysis verb
  through the configured command executor. This keeps Ripwire's full command
  surface out of every model prompt.
  """

  # Every exposed action is analytical. Ripwire may maintain its own index or
  # cache, but it receives no edit verb through this adapter.
  use Alto.Tool, name: :ripwire, execution_mode: :parallel, approval: :never, arguments: true

  alias Alto.Command
  alias Alto.Tool.Arguments

  @actions ~w(pack_task context situ impact callers test_gate edit_check quality_delta pr_context)

  @impl true
  def arguments(_opts) do
    {"Use the external Ripwire code map for task orientation, blast radius, callers, tests, and change-quality checks.",
     [
       action: [type: {:in, @actions}, required: true],
       query: [
         type: Arguments.text(1, :infinity),
         doc:
           "Task text for pack_task/context, symbol for impact/callers/edit_check, or ref for pr_context."
       ],
       top_k: [type: {:in, 1..100}]
     ]}
  end

  @impl true
  def run(arguments, %{} = context, opts \\ []) do
    action = Map.get(arguments, "action")
    top_k = for value <- List.wrap(arguments["top_k"]), do: "--top-k=#{value}"

    with {:ok, flag} <- action_flag(action, arguments["query"]),
         {:ok, result} <-
           Command.run(
             %{
               "program" => Keyword.get(opts, :executable, "ripwire"),
               "args" => [".", flag] ++ top_k,
               "timeout_ms" => Keyword.get(opts, :timeout_ms, 60_000),
               "max_output_bytes" =>
                 Keyword.get(opts, :max_output_bytes, Alto.Command.default_output_bytes())
             },
             context,
             Keyword.take(opts, [:executor, :policy])
           ) do
      command_result(action, result)
    end
  end

  defp action_flag(action, nil) when action in ~w(situ test_gate quality_delta),
    do: {:ok, "--" <> String.replace(action, "_", "-")}

  defp action_flag(action, query) when is_binary(query) and query != "" do
    if action in ~w(situ test_gate quality_delta) do
      {:error, {:unexpected_ripwire_query, action}}
    else
      name = if action == "context", do: "for", else: String.replace(action, "_", "-")
      {:ok, "--" <> name <> "=" <> query}
    end
  end

  defp action_flag(action, _query), do: {:error, {:ripwire_query_required, action}}

  defp command_result(_action, %{termination: :timeout}), do: {:error, :ripwire_timeout}

  # Ripwire uses these non-zero statuses as domain verdicts. They must remain
  # usable tool results so the agent can inspect and act on the reported work.
  defp command_result("test_gate", %{exit_status: 4} = result),
    do: {:ok, Map.put(result, :gate, :obligations)}

  defp command_result("quality_delta", %{exit_status: 2} = result),
    do: {:ok, Map.put(result, :gate, :regressions)}

  defp command_result(action, %{exit_status: 0} = result)
       when action in ["test_gate", "quality_delta"],
       do: {:ok, Map.put(result, :gate, :clear)}

  defp command_result(_action, %{exit_status: 0} = result), do: {:ok, result}

  defp command_result(_action, %{exit_status: status, output: output}),
    do: {:error, {:ripwire_failed, status, output}}

  defp command_result(_action, result), do: {:error, {:ripwire_failed, result}}
end
