defmodule Alto.Approval.DelegatedTest do
  use ExUnit.Case, async: true

  alias Alto.Approval

  test "the prepared approval is correlated without giving the front end executable state" do
    parent = self()

    request = %{
      id: "run-1:op-1",
      run_id: "run-1",
      call_id: "provider-call",
      tool: "git_mutate",
      arguments: %{"action" => "stage"},
      execution_mode: :exclusive,
      details: %{command: "git add"}
    }

    task =
      Task.async(fn ->
        Approval.delegated(request, %{session_id: "run-1", cwd: "/tmp"}, sink: parent)
      end)

    assert_receive {:alto_approval_request, "run-1", ^request, waiter}
    send(waiter, {:alto_approval_decision, request.id, :approve})
    assert Task.await(task) == :approve
  end

  test "fails closed without a front end" do
    request = %{
      id: "id",
      run_id: "run",
      call_id: nil,
      tool: "write",
      arguments: %{},
      execution_mode: :exclusive,
      details: %{}
    }

    assert Approval.delegated(request, %{session_id: "run", cwd: "/tmp"}, []) ==
             {:deny, :approval_front_end_unavailable}
  end
end
