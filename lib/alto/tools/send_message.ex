defmodule Alto.Tools.SendMessage do
  @moduledoc "Send attributed input through the same channel used for user steering."
  use Alto.Tool,
    name: :send_message,
    runtime_operation: :send_message,
    execution_mode: :exclusive,
    approval: :never,
    arguments: true

  alias Alto.Tool.Arguments

  @impl true
  def arguments(_opts) do
    {"Queue a message to an agent_id from start_agents or list_agents. Sender identity is supplied by the runtime. Steering is consumed at the next safe model boundary; follow_up waits until the task would finish. Queued does not mean read. A reply is a separate message.",
     [
       to: [
         type: :string,
         required: true,
         doc:
           "Copy the complete agent_id verbatim from list_agents, preserving any prefix such as agent-. Do not use a label or shortened ID. After resuming a conversation, call list_agents again: IDs in older messages may no longer be registered."
       ],
       text: [type: Arguments.text(1, 64_000), required: true],
       delivery: [type: {:in, ["steer", "follow_up"]}, default: "steer"],
       idempotency_key: [type: {:or, [Arguments.text(1, 256), {:in, [nil]}]}],
       in_reply_to: [type: {:or, [Arguments.text(1, 256), {:in, [nil]}]}]
     ]}
  end

  @impl true
  def run(args, context, _opts) do
    mode = if args["delivery"] == "steer", do: :steer, else: :follow_up

    result =
      Alto.Messaging.send(context[:messaging], args["to"],
        text: args["text"],
        delivery: mode,
        idempotency_key: args["idempotency_key"],
        in_reply_to: args["in_reply_to"]
      )

    case result do
      {:error, :unknown_agent} -> unknown_recipient(args["to"], context[:messaging])
      other -> other
    end
  end

  defp unknown_recipient(to, sender) do
    suggestion =
      with true <- is_binary(to),
           {:ok, agents} <- Alto.Messaging.list(sender),
           agent when not is_nil(agent) <- Enum.find(agents, &(&1.agent_id == "agent-" <> to)),
           do: agent.agent_id,
           else: (_ -> nil)

    {:error,
     {:unknown_agent,
      %{
        requested: to,
        suggested_agent_id: suggestion,
        hint:
          if(suggestion,
            do:
              "Use the complete agent_id from list_agents, including its prefix. No message was delivered.",
            else:
              "This recipient is not registered in the current agent tree. Call list_agents and choose the current recipient; IDs from an earlier run may be stale. No message was delivered."
          )
      }}}
  end
end
