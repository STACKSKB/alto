defmodule Alto.Transition do
  @moduledoc "A loop transition returned to the runtime interpreter."

  alias Alto.Effect

  @enforce_keys [:status, :state, :effects]
  defstruct [:status, :state, :effects, :result, :error]

  @type status :: :continue | :stop | :error
  @type t :: %__MODULE__{
          status: status(),
          state: term(),
          effects: [Effect.t()],
          result: term() | nil,
          error: term() | nil
        }

  @spec continue(term(), [Effect.t()]) :: t()
  def continue(state, effects \\ []) do
    %__MODULE__{status: :continue, state: state, effects: effects}
  end

  @spec stop(term(), term(), [Effect.t()]) :: t()
  def stop(state, result, effects \\ []) do
    %__MODULE__{status: :stop, state: state, result: result, effects: effects}
  end

  @spec error(term(), term(), [Effect.t()]) :: t()
  def error(state, reason, effects \\ []) do
    %__MODULE__{status: :error, state: state, error: reason, effects: effects}
  end

  @doc "Place effects before work already requested by the inner transition."
  @spec prepend_effects(t(), [Effect.t()]) :: t()
  def prepend_effects(%__MODULE__{} = transition, effects) when is_list(effects) do
    %{transition | effects: effects ++ transition.effects}
  end
end
