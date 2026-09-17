defmodule Alto.Provider do
  @moduledoc """
  Contract for provider adapters. Provider calls run under runtime supervision.

  A request may set `tool_choice: :none` to retain historical tool schemas while
  requesting text only (for example, context reduction). Adapters translate it
  to their wire protocol. Reduction never dispatches returned tool calls, even
  if an adapter or model ignores this hint.
  """

  alias Alto.Event

  @type sink :: (Event.t() -> any())
  @type completion :: %{
          required(:message) => String.t() | nil,
          required(:tool_calls) => [map()],
          optional(:usage) => map() | nil,
          optional(:reasoning) => String.t() | nil,
          optional(:provider_fields) => map()
        }
  @type model :: %{
          required(:id) => String.t(),
          optional(:name) => String.t(),
          optional(:context_length) => pos_integer(),
          optional(:supported_parameters) => [String.t()],
          optional(:reasoning) => map(),
          optional(:efforts) => [String.t() | map()]
        }

  @callback describe(keyword()) :: map()
  @callback list_models(keyword()) :: {:ok, [model()]} | {:error, term()}
  @callback stream(request :: map(), sink(), keyword()) ::
              {:ok, completion()} | {:error, term()}

  @optional_callbacks list_models: 1
end
