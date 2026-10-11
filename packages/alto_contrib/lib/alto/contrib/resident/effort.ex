defmodule Alto.Contrib.Resident.Effort do
  @moduledoc "Discover public effort capabilities for a service-owned model."

  def catalog(config, profile) do
    with {:ok, options} <- Alto.Contrib.Resident.Config.resolve(config, profile),
         {:ok, module, opts} <- provider(options),
         {:ok, models} <- models(options, module, opts) do
      id = opts[:model]
      model = Enum.find(models, &((&1[:id] || &1["id"]) == id))
      {:ok, %{model: id, efforts: Alto.Contrib.Reasoning.efforts(model)}}
    else
      {:error, :provider_required} -> {:ok, %{model: nil, efforts: []}}
      error -> error
    end
  end

  def model(options) do
    case provider(options) do
      {:ok, _module, opts} -> opts[:model]
      _ -> nil
    end
  end

  defp provider(options) do
    case options[:provider] do
      {module, opts} when is_atom(module) and is_list(opts) -> {:ok, module, opts}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, []}
      _ -> {:error, :provider_required}
    end
  end

  defp models(options, module, opts) do
    with {:ok, profiles} <- Alto.Contrib.ProviderProfile.from_run_options(options) do
      configured =
        Enum.find(profiles, fn profile ->
          elem(profile.provider, 0) == module and profile.default_model == opts[:model] and
            is_list(profile.models)
        end)

      cond do
        is_list(opts[:reasoning_efforts]) ->
          {:ok, [%{id: opts[:model], efforts: opts[:reasoning_efforts]}]}

        configured ->
          {:ok, configured.models}

        Code.ensure_loaded?(module) and function_exported?(module, :list_models, 1) ->
          Alto.Provider.list_models({module, Keyword.put(opts, :timeout, 5000)})

        true ->
          {:ok, []}
      end
    end
  end
end
