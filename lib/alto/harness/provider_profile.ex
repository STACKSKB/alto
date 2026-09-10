defmodule Alto.Harness.ProviderProfile do
  @moduledoc """
  A selectable provider entry for interactive harness front ends.

  Profiles are configuration, not credentials storage. Provider options may
  reference credentials resolved by a trusted `alto.exs`; front ends display
  only `id`, `label`, and model names.
  """

  @enforce_keys [:id, :label, :module, :options]
  defstruct [:id, :label, :module, :options, :default_model, :credential_id, models: :discover]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          module: module(),
          options: keyword(),
          models: :discover | [Alto.Provider.model()],
          default_model: String.t() | nil,
          credential_id: String.t()
        }

  @doc "Normalize configured profiles or derive one from the run provider."
  @spec from_run_options(keyword()) :: {:ok, [t()]} | {:error, term()}
  def from_run_options(run_options) when is_list(run_options) do
    case Keyword.get(run_options, :provider_profiles) do
      nil -> derive(Keyword.get(run_options, :provider))
      profiles when is_list(profiles) -> normalize_all(profiles)
      other -> {:error, {:invalid_provider_profiles, other}}
    end
  end

  @doc "Return the Alto provider spec for a selected model."
  @spec provider(t(), String.t()) :: {module(), keyword()}
  def provider(%__MODULE__{} = profile, model) when is_binary(model) and model != "" do
    {profile.module, Keyword.put(profile.options, :model, model)}
  end

  @doc "Return a provider spec with credentials resolved at the execution boundary."
  @spec runtime_provider(t(), String.t(), keyword()) :: {module(), keyword()}
  def runtime_provider(%__MODULE__{} = profile, model, opts \\ [])
      when is_binary(model) and model != "" do
    options = Alto.Harness.ProviderStore.runtime_options(profile, opts)
    {profile.module, Keyword.put(options, :model, model)}
  end

  @doc "Fetch or return the profile's bounded model catalog."
  @spec models(t(), keyword()) :: {:ok, [Alto.Provider.model()]} | {:error, term()}
  def models(profile, opts \\ [])

  def models(%__MODULE__{models: models}, _opts) when is_list(models), do: {:ok, models}

  def models(%__MODULE__{models: :discover, module: module} = profile, opts) do
    if function_exported?(module, :list_models, 1) do
      module.list_models(Alto.Harness.ProviderStore.runtime_options(profile, opts))
    else
      {:error, {:model_discovery_not_supported, module}}
    end
  end

  defp derive(nil), do: {:ok, []}

  defp derive({module, options}) when is_atom(module) and is_list(options) do
    normalize_all([
      [
        id: module |> Module.split() |> List.last() |> Macro.underscore(),
        label: module |> Module.split() |> List.last(),
        provider: {module, options},
        models: :discover
      ]
    ])
  end

  defp derive(module) when is_atom(module), do: derive({module, []})
  defp derive(other), do: {:error, {:invalid_provider, other}}

  defp normalize_all(profiles) do
    with {:ok, normalized} <- map_ok(profiles, &normalize/1),
         :ok <- unique_ids(normalized) do
      {:ok, normalized}
    end
  end

  defp normalize(%__MODULE__{} = profile), do: validate(profile)

  defp normalize(profile) when is_list(profile) do
    if Keyword.keyword?(profile),
      do: normalize(Map.new(profile)),
      else: {:error, :invalid_profile}
  end

  defp normalize(profile) when is_map(profile) do
    id = get(profile, :id)
    label = get(profile, :label) || id
    models = normalize_models(get(profile, :models, :discover))

    case get(profile, :provider) do
      {module, options} when is_atom(module) and is_list(options) ->
        validate(%__MODULE__{
          id: id,
          label: label,
          module: module,
          options: options,
          models: models,
          default_model: get(profile, :default_model) || Keyword.get(options, :model),
          credential_id: get(profile, :credential_id) || id
        })

      module when is_atom(module) ->
        options = get(profile, :options, [])

        validate(%__MODULE__{
          id: id,
          label: label,
          module: module,
          options: options,
          models: models,
          default_model: get(profile, :default_model) || Keyword.get(options, :model),
          credential_id: get(profile, :credential_id) || id
        })

      other ->
        {:error, {:invalid_profile_provider, id, other}}
    end
  end

  defp normalize(other), do: {:error, {:invalid_provider_profile, other}}

  defp validate(%__MODULE__{} = profile) do
    cond do
      not valid_name?(profile.id) ->
        {:error, {:invalid_profile_id, profile.id}}

      not valid_name?(profile.label) ->
        {:error, {:invalid_profile_label, profile.label}}

      not is_atom(profile.module) ->
        {:error, {:invalid_profile_module, profile.module}}

      not Keyword.keyword?(profile.options) ->
        {:error, {:invalid_profile_options, profile.id}}

      not valid_name?(profile.credential_id) ->
        {:error, {:invalid_profile_credential_id, profile.credential_id}}

      profile.models == :invalid ->
        {:error, {:invalid_profile_models, profile.id}}

      true ->
        {:ok, profile}
    end
  end

  defp normalize_models(:discover), do: :discover

  defp normalize_models(models) when is_list(models) do
    Enum.flat_map(models, fn
      id when is_binary(id) and id != "" ->
        [%{id: id, name: id}]

      %{id: id} = model when is_binary(id) and id != "" ->
        [model]

      %{"id" => id} = model when is_binary(id) and id != "" ->
        [%{id: id, name: Map.get(model, "name", id)}]

      _other ->
        []
    end)
  end

  defp normalize_models(_other), do: :invalid

  defp unique_ids(profiles) do
    ids = Enum.map(profiles, & &1.id)
    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, :duplicate_profile_id}
  end

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp valid_name?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 200 and String.valid?(value)
end
