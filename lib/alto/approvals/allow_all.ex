defmodule Alto.Approvals.AllowAll do
  @moduledoc "Approval policy that authorizes every requested invocation."

  @behaviour Alto.Approval

  @impl true
  def decide(_request, _context, _opts), do: :approve
end
