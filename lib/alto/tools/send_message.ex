defmodule Alto.Tools.SendMessage do
  @moduledoc "Send attributed input through the same channel used for user steering."
  use Alto.Tool, name: :send_message, execution_mode: :exclusive, approval: :never

  @impl true
  def schema(_opts) do
    Alto.Tool.object_schema(
      "Queue a message to an agent_id from start_agents or list_agents. Sender identity is supplied by the runtime. Steering is consumed at the next safe model boundary; follow_up waits until the task would finish. Queued does not mean read. A reply is a separate message.",
      %{
        to: %{type: "string"},
        text: %{type: "string", maxLength: 64000},
        delivery: %{type: "string", enum: ["steer", "follow_up"]},
        idempotency_key: %{type: "string", maxLength: 256},
        in_reply_to: %{type: "string", maxLength: 256}
      },
      ["to", "text"]
    )
  end

  @impl true
  def run(%{"to" => to, "text" => text} = args, context, _opts) when is_binary(to) do
    if Map.keys(args) -- ["to", "text", "delivery", "idempotency_key", "in_reply_to"] == [] do
      mode =
        case Map.get(args, "delivery", "steer") do
          "steer" -> :steer
          "follow_up" -> :follow_up
          _ -> :invalid
        end

      Alto.Messaging.send(context.messaging, to,
        text: text,
        delivery: mode,
        idempotency_key: args["idempotency_key"],
        in_reply_to: args["in_reply_to"]
      )
    else
      {:error, :invalid_message}
    end
  end

  def run(_, _, _), do: {:error, :invalid_message}
end
