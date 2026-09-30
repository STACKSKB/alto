defmodule Alto.Contrib.Credentials do
  @moduledoc """
  Small per-user credential and provider-preference store.

  Credentials are never loaded from a workspace. The on-disk JSON file is
  atomically replaced with mode `0600` and bounded before decoding.
  """

  @version 1
  @max_bytes 64_000

  @enforce_keys [:path, :providers]
  defstruct [:path, :providers]

  @type t :: %__MODULE__{path: Path.t(), providers: %{optional(String.t()) => map()}}

  @doc "Return the per-user credentials path without creating it."
  @spec default_path() :: Path.t()
  def default_path do
    Path.join(Path.dirname(Alto.Contrib.Config.default_path()), "credentials.json")
  end

  @doc "Load a bounded credential store, returning an empty store when absent."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ default_path()) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, document} <- read(expanded),
         do: {:ok, %__MODULE__{path: expanded, providers: document["providers"]}}
  end

  @doc "Fetch a saved provider value such as `api_key` or `model`."
  @spec get(t(), String.t(), String.t()) :: String.t() | nil
  def get(%__MODULE__{providers: providers}, provider, key)
      when is_binary(provider) and is_binary(key) do
    case get_in(providers, [provider, key]) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @doc "Merge provider values and atomically persist the credential store."
  @spec put(t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def put(%__MODULE__{} = credentials, provider, values)
      when is_binary(provider) and provider != "" and is_map(values) do
    with :ok <- validate_values(values) do
      path = Path.expand(credentials.path)

      Alto.Storage.update_json(path, @max_bytes, fn -> read(path) end, fn document ->
        updated =
          update_in(
            document["providers"],
            &Map.update(&1, provider, values, fn prior -> Map.merge(prior, values) end)
          )

        {:ok, updated, %__MODULE__{path: path, providers: updated["providers"]}}
      end)
    end
  end

  def put(_credentials, _provider, _values), do: {:error, :invalid_credentials_update}

  defp read(path) do
    case Alto.Storage.read_json(path, @max_bytes, nil, &valid_document?/1) do
      {:ok, nil} -> {:ok, %{"version" => @version, "providers" => %{}}}
      {:ok, document} -> with :ok <- private_mode?(path), do: {:ok, document}
      error -> error
    end
  end

  defp valid_document?(%{"version" => @version, "providers" => providers}),
    do: valid_providers?(providers)

  defp valid_document?(_), do: false

  # A store that group or other can read is refused rather than trusted;
  # running setup again rewrites it with mode 0600.
  defp private_mode?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %{mode: _mode}} -> {:error, {:credentials_mode, path}}
      {:error, reason} -> {:error, {:snapshot_read_failed, path, reason}}
    end
  end

  defp validate_values(values) do
    if Enum.all?(values, fn {key, value} ->
         is_binary(key) and key != "" and is_binary(value) and value != ""
       end) do
      :ok
    else
      {:error, :invalid_credentials_update}
    end
  end

  defp valid_providers?(providers) when is_map(providers) do
    Enum.all?(providers, fn {provider, values} ->
      is_binary(provider) and provider != "" and is_map(values) and
        validate_values(values) == :ok
    end)
  end

  defp valid_providers?(_providers), do: false
end

defimpl Inspect, for: Alto.Contrib.Credentials do
  import Inspect.Algebra

  def inspect(credentials, _opts) do
    concat(["#Alto.Contrib.Credentials<", credentials.path, ">"])
  end
end
