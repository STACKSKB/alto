defmodule Alto.Harness.ProviderStore do
  @moduledoc """
  Persists user-configured OpenAI-compatible providers and resolves their secrets.

  Provider metadata is safe to keep in TUI state. API keys stay in
  `Alto.Credentials` and are only merged into the short-lived provider options
  used for discovery or a run.
  """

  alias Alto.Credentials
  alias Alto.Harness.ProviderProfile

  @kind "openai_compatible"
  @openrouter_url "https://openrouter.ai/api/v1"

  @doc "Merge provider metadata saved by the TUI with configured profiles."
  @spec profiles([ProviderProfile.t()], keyword()) ::
          {:ok, [ProviderProfile.t()]} | {:error, term()}
  def profiles(configured, opts \\ []) when is_list(configured) do
    with {:ok, credentials} <- Credentials.load(path(opts)),
         do: {:ok, effective_profiles(configured, credentials.providers)}
  end

  defp effective_profiles(configured, records) do
    configured_ids = MapSet.new(Enum.flat_map(configured, &[&1.id, &1.credential_id]))

    added =
      for {id, %{"type" => @kind}} <- records,
          not MapSet.member?(configured_ids, id),
          do: %ProviderProfile{
            id: id,
            label: id,
            credential_id: id,
            provider:
              {Alto.Providers.OpenAICompatible, [base_url: @openrouter_url, timeout: 120_000]}
          }

    Enum.map(
      configured ++ Enum.sort_by(added, &String.downcase(records[&1.id]["label"] || &1.label)),
      &decorate(&1, Map.get(records, &1.credential_id, %{}))
    )
  end

  @doc "Save provider metadata and return the same effective profiles used at startup."
  @spec save(map(), [ProviderProfile.t()], keyword()) ::
          {:ok, [ProviderProfile.t()]} | {:error, term()}
  def save(attrs, configured, opts \\ []) when is_map(attrs) and is_list(configured) do
    id = value(attrs, :id)
    label = value(attrs, :label)
    base_url = value(attrs, :base_url)
    api_key = value(attrs, :api_key)
    model = value(attrs, :model)

    with :ok <- validate_id(id),
         :ok <- validate_label(label),
         :ok <- validate_url(base_url),
         {:ok, credentials} <- Credentials.load(path(opts)),
         values <-
           compact(%{
             "type" => @kind,
             "label" => label,
             "base_url" => String.trim_trailing(base_url, "/"),
             "api_key" => api_key,
             "model" => model
           }),
         existing = Enum.find(configured, &(&1.id == id)),
         {:ok, credentials} <-
           Credentials.put(
             credentials,
             if(existing, do: existing.credential_id, else: id),
             values
           ) do
      {:ok, effective_profiles(configured, credentials.providers)}
    end
  end

  @doc "Whether a profile already has a saved API key."
  @spec api_key_saved?(ProviderProfile.t(), keyword()) :: boolean()
  def api_key_saved?(%ProviderProfile{} = profile, opts \\ []) do
    with {:ok, credentials} <- Credentials.load(path(opts)) do
      is_binary(Credentials.get(credentials, profile.credential_id, "api_key"))
    else
      _error -> false
    end
  end

  @doc "Resolve the provider spec with credentials at the execution boundary."
  @spec resolve(ProviderProfile.t(), keyword()) :: {module(), keyword()}
  def resolve(%ProviderProfile{provider: {module, options}} = profile, opts \\ []) do
    record =
      case Credentials.load(path(opts)) do
        {:ok, credentials} -> Map.get(credentials.providers, profile.credential_id, %{})
        {:error, _reason} -> %{}
      end

    api_key = environment_key(profile) || Map.get(record, "api_key")

    options =
      options
      |> maybe_put(:base_url, Map.get(record, "base_url"))
      |> maybe_put(:api_key, api_key)

    {module, options}
  end

  defp decorate(%{provider: {module, options}} = profile, record) do
    %{
      profile
      | label: Map.get(record, "label", profile.label),
        provider: {module, maybe_put(options, :base_url, Map.get(record, "base_url"))},
        default_model: Map.get(record, "model", profile.default_model)
    }
  end

  defp environment_key(%ProviderProfile{id: "openrouter"}),
    do: System.get_env("OPENROUTER_API_KEY")

  defp environment_key(_profile), do: nil

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,63}$/, id),
      do: :ok,
      else: {:error, :provider_id_must_be_lowercase_slug}
  end

  defp validate_id(_id), do: {:error, :provider_id_required}

  defp validate_label(label) when is_binary(label) and label != "" and byte_size(label) <= 120,
    do: :ok

  defp validate_label(_label), do: {:error, :provider_name_required}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _other ->
        {:error, :provider_base_url_must_be_http}
    end
  end

  defp validate_url(_url), do: {:error, :provider_base_url_required}

  defp compact(values),
    do: Map.reject(values, fn {_key, value} -> not is_binary(value) or value == "" end)

  defp maybe_put(options, _key, value) when not is_binary(value) or value == "", do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp value(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> case do
      value when is_binary(value) -> String.trim(value)
      other -> other
    end
  end

  defp path(opts), do: Keyword.get(opts, :credentials_path, Credentials.default_path())
end
