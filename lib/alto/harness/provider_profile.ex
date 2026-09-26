defmodule Alto.Harness.ProviderProfile do
  @moduledoc """
  A selectable provider entry for interactive harness front ends.

  Profiles are configuration, not credentials storage. Provider options may
  reference credentials resolved by a trusted `alto.exs`; front ends display
  only `id`, `label`, and model names.
  """

  @enforce_keys [:id, :label, :provider]
  defstruct [:id, :label, :provider, :default_model, :credential_id, models: :discover]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          provider: {module(), keyword()},
          models: :discover | [Alto.Provider.model()],
          default_model: String.t() | nil,
          credential_id: String.t()
        }

  @doc """
  Normalize atom-keyed profile maps or keywords, or derive one from the run provider.
  `:provider` is a module or `{module, options}`; options belong to that spec.
  """
  @spec from_run_options(keyword()) :: {:ok, [t()]} | {:error, term()}
  def from_run_options(run_options) when is_list(run_options) do
    case Keyword.get(run_options, :provider_profiles) do
      nil -> derive(Keyword.get(run_options, :provider))
      profiles when is_list(profiles) -> normalize_all(profiles)
      other -> {:error, {:invalid_provider_profiles, other}}
    end
  end

  @doc "Return a provider spec with credentials resolved at the execution boundary."
  @spec runtime_provider(t(), String.t(), keyword()) :: {module(), keyword()}
  def runtime_provider(%__MODULE__{} = profile, model, opts \\ [])
      when is_binary(model) and model != "" do
    {module, options} = Alto.Harness.ProviderStore.resolve(profile, opts)
    {module, Keyword.put(options, :model, model)}
  end

  @doc "Fetch or return the profile's bounded model catalog."
  @spec models(t(), keyword()) :: {:ok, [Alto.Provider.model()]} | {:error, term()}
  def models(profile, opts \\ [])

  def models(%__MODULE__{models: models}, _opts) when is_list(models), do: {:ok, models}

  def models(%__MODULE__{models: :discover, provider: {module, _options}} = profile, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :list_models, 1) do
      {^module, options} = Alto.Harness.ProviderStore.resolve(profile, opts)
      module.list_models(options)
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
    with {:ok, normalized} <- Alto.Result.traverse(profiles, &normalize/1),
         :ok <- unique_ids(normalized) do
      {:ok, normalized}
    end
  end

  defp normalize(%__MODULE__{} = profile), do: normalize(Map.from_struct(profile))

  defp normalize(profile) when is_list(profile) do
    if Keyword.keyword?(profile),
      do: normalize(Map.new(profile)),
      else: {:error, :invalid_profile}
  end

  defp normalize(%{id: id, provider: provider} = values) do
    provider = if is_atom(provider), do: {provider, []}, else: provider

    with true <-
           Map.keys(values) -- ~w(id label provider models default_model credential_id)a == [],
         {module, options} <- provider,
         true <- is_atom(module) and not is_nil(module) and Keyword.keyword?(options) do
      profile = struct(__MODULE__, values)

      profile = %{
        profile
        | provider: provider,
          label: profile.label || id,
          credential_id: profile.credential_id || id,
          models: normalize_models(profile.models),
          default_model: profile.default_model || Keyword.get(options, :model)
      }

      if Enum.all?([profile.id, profile.label, profile.credential_id], &valid_name?/1) and
           profile.models != :invalid,
         do: {:ok, profile},
         else: {:error, :invalid_profile}
    else
      _ -> {:error, :invalid_profile}
    end
  end

  defp normalize(_), do: {:error, :invalid_profile}

  defp normalize_models(:discover), do: :discover

  defp normalize_models(models) when is_list(models) do
    Enum.flat_map(models, fn
      id when is_binary(id) and id != "" ->
        [%{id: id, name: id}]

      %{id: id} = model when is_binary(id) and id != "" ->
        [model]

      %{"id" => id} = model when is_binary(id) and id != "" ->
        [Map.merge(model, %{id: id, name: Map.get(model, "name", id)})]

      _other ->
        []
    end)
  end

  defp normalize_models(_other), do: :invalid

  defp unique_ids(profiles) do
    ids = Enum.map(profiles, & &1.id)
    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, :duplicate_profile_id}
  end

  defp valid_name?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 200 and String.valid?(value)
end
