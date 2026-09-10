defmodule Alto.Middleware do
  @moduledoc "Ordered middleware around a loop event transition."

  alias Alto.Event
  alias Alto.Transition

  @type next :: (Event.t() -> Transition.t())

  @callback call(Event.t(), context :: map(), next(), keyword()) :: Transition.t()

  @spec call(module() | {module(), keyword()}, Event.t(), map(), next()) :: Transition.t()
  def call({module, opts}, %Event{} = event, context, next) do
    module.call(event, context, next, opts)
  end

  def call(module, %Event{} = event, context, next) when is_atom(module) do
    module.call(event, context, next, [])
  end
end
