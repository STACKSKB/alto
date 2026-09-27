defmodule Alto.Provider do
  @moduledoc """
  Contract for provider adapters. Provider calls run under runtime supervision.

  A request may set `tool_choice: :none` to retain historical tool schemas while
  requesting text only (for example, context reduction). Adapters translate it
  to their wire protocol. Reduction never dispatches returned tool calls, even
  if an adapter or model ignores this hint.
  """

  @doc "Observe every attempted request, including retries and reductions. Observers run inside the provider call's timeout and cancellation boundary, fail independently, and do not count as streamed output."
  def observe(spec, observer) when is_function(observer, 1) do
    {module, opts} = Alto.Capabilities.normalize(spec)

    {module,
     Keyword.put(opts, :alto_request_observers, [
       observer | Keyword.get(opts, :alto_request_observers, [])
     ])}
  end

  @doc "Provider callback options without host request observers."
  def options(opts), do: Keyword.delete(opts, :alto_request_observers)

  @doc "Notify request observers, then stream through the configured provider. Direct hosts supply their own timeout and cancellation supervision."
  def stream(provider, request, sink, opts) do
    {observers, opts} = Keyword.pop(opts, :alto_request_observers, [])
    Enum.each(observers, &Alto.Events.notify(&1, request))
    provider.stream(request, sink, opts)
  end

  @doc "Discover models through the optional provider callback, without host observers."
  def list_models({module, opts}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :list_models, 1),
      do: module.list_models(options(opts)),
      else: {:error, {:model_discovery_not_supported, module}}
  end

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
