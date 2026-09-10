defmodule Alto.Runtime do
  @moduledoc """
  Pure transition engine shared by every future runtime host.

  This module evaluates loop policy and middleware. Executing the returned
  effects, persisting durable events, and scheduling processes belong to a
  runtime host such as `Alto.Runner.Serial`.
  """

  alias Alto.Event
  alias Alto.Loop.Spec
  alias Alto.Middleware
  alias Alto.Transition

  @spec init(Spec.t(), term()) :: Transition.t()
  def init(%Spec{driver: driver} = spec, task), do: driver.init(task, spec)

  @spec dispatch(Spec.t(), Event.t(), term(), map()) :: Transition.t()
  def dispatch(%Spec{driver: driver} = spec, %Event{} = event, state, context \\ %{}) do
    terminal = fn next_event -> driver.handle_event(next_event, state, spec) end

    pipeline =
      Enum.reduce(Enum.reverse(spec.middleware), terminal, fn middleware, next ->
        fn next_event -> Middleware.call(middleware, next_event, context, next) end
      end)

    pipeline.(event)
  end
end
