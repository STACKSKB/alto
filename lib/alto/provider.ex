defmodule Alto.Provider do
  @moduledoc "Contract for provider adapters. Provider calls run under runtime supervision."

  alias Alto.Event

  @type sink :: (Event.t() -> any())
  @type completion :: %{
          required(:message) => String.t() | nil,
          required(:tool_calls) => [map()],
          optional(:usage) => map() | nil
        }
  @type model :: %{
          required(:id) => String.t(),
          optional(:name) => String.t(),
          optional(:context_length) => pos_integer(),
          optional(:supported_parameters) => [String.t()]
        }

  @callback describe(keyword()) :: map()
  @callback list_models(keyword()) :: {:ok, [model()]} | {:error, term()}
  @callback stream(request :: map(), sink(), keyword()) ::
              {:ok, completion()} | {:error, term()}

  @optional_callbacks list_models: 1
end
