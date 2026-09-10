defmodule Alto.Approvals.DenyAll do
  @moduledoc "Approval policy that denies every requested invocation."

  @behaviour Alto.Approval

  @impl true
  def decide(_request, _context, opts), do: {:deny, Keyword.get(opts, :reason, :policy_denied)}
end
