defmodule Alto.Hook do
  @moduledoc "A lifecycle hook that returns ordered runtime effects."

  alias Alto.Effect
  alias Alto.Event

  @type handler :: module() | {module(), keyword()} | (Event.t(), map() -> [Effect.t()])

  @callback handle(Event.t(), context :: map(), keyword()) :: [Effect.t()]

  @spec run(handler(), Event.t(), map()) :: [Effect.t()]
  def run({module, opts}, %Event{} = event, context) when is_atom(module) do
    validate!(module.handle(event, context, opts))
  end

  def run(module, %Event{} = event, context) when is_atom(module) do
    validate!(module.handle(event, context, []))
  end

  def run(handler, %Event{} = event, context) when is_function(handler, 2) do
    validate!(handler.(event, context))
  end

  defp validate!(effects) when is_list(effects) do
    if Enum.all?(effects, &match?(%Effect{}, &1)) do
      effects
    else
      raise ArgumentError, "hooks must return a list of Alto.Effect values"
    end
  end

  defp validate!(_other) do
    raise ArgumentError, "hooks must return a list of Alto.Effect values"
  end
end
