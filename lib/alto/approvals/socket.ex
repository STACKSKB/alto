defmodule Alto.Approvals.Socket do
  @moduledoc """
  Approval policy for resident runs: the display-safe request is published to
  front ends attached through `Alto.FrontEnd.Registry`, and the policy process
  waits for the correlated decision.

  Fail-closed by construction: an unavailable or unknown registry denies
  immediately, an unaddressable request (no call id) denies, and the host's
  supervised call with its `approval_timeout` bounds the wait — a closed or
  hung front end cannot stall a run longer than the configured timeout, and
  cannot widen it either.
  """

  @behaviour Alto.Approval

  @impl true
  def decide(request, context, _opts)

  def decide(%Alto.Approval.Request{id: nil}, _context, _opts) do
    {:deny, :approval_request_unaddressable}
  end

  def decide(%Alto.Approval.Request{id: id} = request, context, _opts) do
    registry =
      Map.get(Map.get(context, :metadata, %{}), :front_end_registry, Alto.FrontEnd.Registry)

    case Alto.FrontEnd.Registry.request_approval(registry, context.session_id, request, self()) do
      :ok ->
        receive do
          {:alto_approval_decision, ^id, decision} -> decision
        end

      {:error, reason} ->
        {:deny, {:approval_unavailable, reason}}
    end
  catch
    :exit, reason -> {:deny, {:approval_unavailable, {:registry_exit, reason}}}
  end
end
