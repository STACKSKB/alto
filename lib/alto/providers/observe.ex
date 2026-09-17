defmodule Alto.Providers.Observe do
  @moduledoc """
  Composable request observation at the supervised provider boundary.

  `wrap/2` returns an ordinary provider specification. The observer receives
  each attempted request, including retries and reduction requests, unchanged.
  It chooses its own output destination; observations are not model output.
  Exceptions, throws and exits from the observer are ignored. Execution's
  existing provider timeout and cancellation also bound observation work.

  Provider options remain at the top level so profile model selection,
  credentials and routing identity continue to work normally. Wrappers nest.
  """
  @behaviour Alto.Provider

  def wrap(provider, observer) when is_atom(provider), do: wrap({provider, []}, observer)

  def wrap({provider, options}, observer)
      when is_atom(provider) and is_list(options) and is_function(observer, 1) do
    layers = Keyword.get(options, :alto_request_observers, [])
    {__MODULE__, Keyword.put(options, :alto_request_observers, [{provider, observer} | layers])}
  end

  @impl true
  def describe(options) do
    {provider, _observer, options} = unwrap(options)
    provider.describe(options)
  end

  @impl true
  def list_models(options) do
    {provider, _observer, options} = unwrap(options)

    if Code.ensure_loaded?(provider) and function_exported?(provider, :list_models, 1),
      do: provider.list_models(options),
      else: {:error, :model_discovery_unsupported}
  end

  @impl true
  def stream(request, sink, options) do
    {provider, observer, options} = unwrap(options)
    observe(observer, request)
    provider.stream(request, sink, options)
  end

  defp unwrap(options) do
    {[{provider, observer} | rest], options} = Keyword.pop!(options, :alto_request_observers)

    options =
      if rest == [], do: options, else: Keyword.put(options, :alto_request_observers, rest)

    {provider, observer, options}
  end

  defp observe(observer, request) do
    observer.(request)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
