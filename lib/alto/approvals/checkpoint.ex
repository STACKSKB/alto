defmodule Alto.Approvals.Checkpoint do
  @moduledoc "Suspend for a durable host decision before executing an approved tool."
  @behaviour Alto.Approval
  @impl true
  def decide(_request, _context, _opts), do: :suspend
end
