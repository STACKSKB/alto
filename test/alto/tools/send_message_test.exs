defmodule Alto.Tools.SendMessageTest do
  use ExUnit.Case, async: true

  test "a missing prefix suggests the exact address but never reroutes a message" do
    {:ok, router} = Alto.Messaging.start_link()
    {:ok, parent} = Alto.Messaging.register(router, id: "agent-parent")
    {:ok, child} = Alto.Messaging.register(router, parent: parent.id)
    {:ok, input} = Alto.Messaging.bind(parent)
    context = %{messaging: child}
    args = %{"to" => "parent", "text" => "status", "delivery" => "steer"}

    assert {:error, {:unknown_agent, %{suggested_agent_id: "agent-parent"}}} =
             Alto.Tools.SendMessage.run(args, context, [])

    assert [] = Alto.Input.request(input, :list)
    assert {:ok, _} = Alto.Tools.SendMessage.run(%{args | "to" => "agent-parent"}, context, [])
    assert [%{text: "status"}] = Alto.Input.request(input, :list)

    assert {:error, {:unknown_agent, %{suggested_agent_id: nil}}} =
             Alto.Tools.SendMessage.run(%{args | "to" => "missing"}, context, [])
  end
end
