defmodule Alto.Approval do
  @moduledoc "Contracts and classifiers for authorizing one prepared external effect."

  @type request :: %{
          id: String.t() | nil,
          run_id: String.t() | nil,
          call_id: String.t() | nil,
          tool: String.t(),
          arguments: map(),
          execution_mode: Alto.Tool.execution_mode(),
          details: map()
        }

  @type decision :: :approve | :suspend | {:deny, term()}

  @type policy :: decision() | (request(), Alto.Tool.context() -> decision())

  @doc "Run a configured classifier; booleans are accepted alongside approval decisions."
  def review(reviewer, request, context) when is_function(reviewer, 2) do
    case reviewer.(request, context) do
      true -> :approve
      false -> {:deny, :reviewer_denied}
      decision -> decision
    end
  end
end
