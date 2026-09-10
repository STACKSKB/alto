defmodule Alto.Loop do
  @moduledoc """
  Contract for a replaceable control loop.

  A loop is a state machine. It receives typed events and returns ordered
  effects for the runtime to interpret. It never calls providers or tools
  directly.
  """

  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Transition

  @callback init(task :: term(), Spec.t()) :: Transition.t()
  @callback handle_event(Event.t(), state :: term(), Spec.t()) :: Transition.t()

  @doc "Run a hook after a lifecycle event has occurred and before continuation effects execute."
  @spec after_event(Spec.t(), atom(), Alto.Hook.handler()) :: Spec.t()
  def after_event(%Spec{} = spec, event_type, hook) when is_atom(event_type) do
    Spec.add_middleware(
      spec,
      {Alto.Middleware.After, event: event_type, hook: hook}
    )
  end
end
