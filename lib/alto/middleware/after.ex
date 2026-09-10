defmodule Alto.Middleware.After do
  @moduledoc false
  @behaviour Alto.Middleware

  alias Alto.Event
  alias Alto.Hook
  alias Alto.Transition

  @impl true
  def call(%Event{} = event, context, next, opts) do
    transition = next.(event)

    if event.type == Keyword.fetch!(opts, :event) do
      effects = Hook.run(Keyword.fetch!(opts, :hook), event, context)
      Transition.prepend_effects(transition, effects)
    else
      transition
    end
  end
end
