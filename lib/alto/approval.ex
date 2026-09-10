defmodule Alto.Approval do
  @moduledoc "Policy boundary for authorizing one external effect."

  alias Alto.Approval.Request
  alias Alto.Tool.Context

  @type decision :: :approve | :suspend | {:deny, term()}

  @callback decide(Request.t(), Context.t(), keyword()) :: decision()
end
