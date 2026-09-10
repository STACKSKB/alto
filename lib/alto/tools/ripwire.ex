defmodule Alto.Tools.Ripwire do
  @moduledoc """
  Bounded adapter for the external Ripwire CLI.

  Ripwire remains an independently installed executable. Alto contributes only
  a small, stable action schema and runs the selected read-only analysis verb
  through the configured command executor. This keeps Ripwire's full command
  surface out of every model prompt.
  """

  @behaviour Alto.Tool

  alias Alto.Command
  alias Alto.Command.Invocation
  alias Alto.Tool.Context

  @actions ~w(pack_task context situ impact callers test_gate edit_check quality_delta pr_context)

  @impl true
  def name, do: :ripwire

  @impl true
  def schema do
    %{
      description:
        "Use the external Ripwire code map for task orientation, blast radius, callers, tests, and change-quality checks.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{type: "string", enum: @actions},
          query: %{
            type: "string",
            description:
              "Task text for pack_task/context, symbol for impact/callers/edit_check, or ref for pr_context."
          },
          top_k: %{type: "integer", minimum: 1, maximum: 100}
        },
        required: ["action"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def execution_mode, do: :parallel

  # Every exposed action is analytical. Ripwire may maintain its own index or
  # cache, but it receives no edit verb through this adapter.
  @impl true
  def approval, do: :never

  @impl true
  def run(arguments, %Context{} = context), do: run(arguments, context, [])

  @impl true
  def run(arguments, %Context{} = context, opts) do
    action = Map.get(arguments, "action")

    with {:ok, args} <- build_args(arguments),
         {:ok, result} <-
           Command.run(
             %{
               "program" => Keyword.get(opts, :executable, "ripwire"),
               "args" => args,
               "timeout_ms" => Keyword.get(opts, :timeout_ms, 60_000),
               "max_output_bytes" =>
                 Keyword.get(opts, :max_output_bytes, min(64_000, Invocation.max_output_bytes()))
             },
             context,
             Keyword.take(opts, [:executor, :policy])
           ) do
      command_result(action, result)
    end
  end

  defp build_args(%{"action" => action} = arguments) when action in @actions do
    with {:ok, flag} <- action_flag(action, Map.get(arguments, "query")),
         {:ok, top_k} <- top_k_flag(Map.get(arguments, "top_k")) do
      {:ok, [".", flag] ++ top_k}
    end
  end

  defp build_args(%{"action" => action}), do: {:error, {:unknown_ripwire_action, action}}
  defp build_args(_arguments), do: {:error, :ripwire_action_required}

  defp action_flag("situ", nil), do: {:ok, "--situ"}
  defp action_flag("test_gate", nil), do: {:ok, "--test-gate"}
  defp action_flag("quality_delta", nil), do: {:ok, "--quality-delta"}

  defp action_flag(action, query) when is_binary(query) and query != "" do
    prefix =
      case action do
        "pack_task" -> "--pack-task="
        "context" -> "--for="
        "impact" -> "--impact="
        "callers" -> "--callers="
        "edit_check" -> "--edit-check="
        "pr_context" -> "--pr-context="
        _other -> nil
      end

    if prefix, do: {:ok, prefix <> query}, else: {:error, {:unexpected_ripwire_query, action}}
  end

  defp action_flag(action, _query), do: {:error, {:ripwire_query_required, action}}

  defp top_k_flag(nil), do: {:ok, []}

  defp top_k_flag(value) when is_integer(value) and value in 1..100,
    do: {:ok, ["--top-k=#{value}"]}

  defp top_k_flag(value), do: {:error, {:invalid_top_k, value}}

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
