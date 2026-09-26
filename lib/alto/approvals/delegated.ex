defmodule Alto.Approvals.Delegated do
  @moduledoc """
  Approval policy that delegates a decision to a trusted local front end.

  The execution host still owns the timeout and cancellation boundary. The
  front end only receives the display-safe prepared request and can reply to
  the one policy process waiting for that exact approval handle.
  Inherited `metadata.approval_route` can identify the front end's owning run;
  the request retains the actual executing run and operation identities.
  """

  @behaviour Alto.Approval

  @impl true
  def decide(request, context, opts) do
    sink = Keyword.get(opts, :sink) || get_in(context.metadata, [:approval_sink])

    if is_pid(sink) do
      route = get_in(context.metadata, [:approval_route]) || context.session_id
      send(sink, {:alto_approval_request, route, request, self()})

      receive do
        {:alto_approval_decision, id, decision} when id == request.id -> decision
      end
    else
      {:deny, :approval_front_end_unavailable}
    end
  end
end
