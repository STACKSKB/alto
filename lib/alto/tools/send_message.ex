defmodule Alto.Tools.SendMessage do
  @moduledoc "Send attributed input through the same channel used for user steering."
  use Alto.Tool,
    name: :send_message,
    execution_mode: :exclusive,
    approval: :never,
    arguments: true

  alias Alto.Tool.Arguments

  @impl true
  def arguments(_opts) do
    {"Queue a message to an agent_id from start_agents or list_agents. Sender identity is supplied by the runtime. Steering is consumed at the next safe model boundary; follow_up waits until the task would finish. Queued does not mean read. A reply is a separate message.",
     [
       to: [type: :string, required: true],
       text: [type: Arguments.text(1, 64_000), required: true],
       delivery: [type: {:in, ["steer", "follow_up"]}, default: "steer"],
       idempotency_key: [type: {:or, [Arguments.text(1, 256), {:in, [nil]}]}],
       in_reply_to: [type: {:or, [Arguments.text(1, 256), {:in, [nil]}]}]
     ]}
  end

  @impl true
  def run(args, context, _opts) do
    mode = if args["delivery"] == "steer", do: :steer, else: :follow_up

    Alto.Messaging.send(context.messaging, args["to"],
      text: args["text"],
      delivery: mode,
      idempotency_key: args["idempotency_key"],
      in_reply_to: args["in_reply_to"]
    )
  end
end
