defmodule Alto.Harness.ProviderProfile do
  @moduledoc """
  A selectable provider entry for interactive harness front ends.

  Profiles are configuration, not credentials storage. Provider options may
  reference credentials resolved by a trusted `alto.exs`; front ends display
  only `id`, `label`, and model names.
  """

  @enforce_keys [:id, :provider]
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
  Read trusted profile structs, or derive one from the run provider.
  Profiles use a `{module, options}` provider and atom-keyed model catalog maps.
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

    metadata =
      opts[:model_metadata] ||
        if(is_list(profile.models), do: Enum.find(profile.models, &(&1.id == model)))

    {module, Alto.InputModalities.bind(options, model, metadata)}
  end

  @doc "Fetch or return the profile's bounded model catalog."
  @spec models(t(), keyword()) :: {:ok, [Alto.Provider.model()]} | {:error, term()}
  def models(profile, opts \\ [])

  def models(%__MODULE__{models: models}, _opts) when is_list(models), do: {:ok, models}

  def models(%__MODULE__{models: :discover} = profile, opts),
    do: profile |> Alto.Harness.ProviderStore.resolve(opts) |> Alto.Provider.list_models()

  defp derive(nil), do: {:ok, []}

  defp derive({module, options}) when is_atom(module) and is_list(options) do
    normalize_all([
      %__MODULE__{
        id: module |> Module.split() |> List.last() |> Macro.underscore(),
        label: module |> Module.split() |> List.last(),
        provider: {module, options}
      }
    ])
  end

  defp derive(module) when is_atom(module), do: derive({module, []})
  defp derive(other), do: {:error, {:invalid_provider, other}}

  defp normalize_all(profiles) do
    profiles =
      Enum.map(profiles, fn %__MODULE__{provider: {_module, options}} = profile ->
        %{
          profile
          | label: profile.label || profile.id,
            credential_id: profile.credential_id || profile.id,
            default_model: profile.default_model || Keyword.get(options, :model)
        }
      end)

    ids = Enum.map(profiles, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: {:ok, profiles},
      else: {:error, :duplicate_profile_id}
  end
end
