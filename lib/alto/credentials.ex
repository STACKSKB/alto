defmodule Alto.Credentials do
  @moduledoc """
  Small per-user credential and provider-preference store.

  Credentials are never loaded from a workspace. The on-disk JSON file is
  atomically replaced with mode `0600` and bounded before decoding.
  """

  alias Alto.Tools.AtomicWrite

  @version 1
  @max_bytes 64_000

  @enforce_keys [:path, :providers]
  defstruct [:path, :providers]

  @type t :: %__MODULE__{path: Path.t(), providers: %{optional(String.t()) => map()}}

  @doc "Return the per-user credentials path without creating it."
  @spec default_path() :: Path.t()
  def default_path do
    Path.join(Path.dirname(Alto.Config.default_path()), "credentials.json")
  end

  @doc "Load a bounded credential store, returning an empty store when absent."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ default_path()) when is_binary(path) do
    expanded = Path.expand(path)

    case bounded_read(expanded) do
      {:ok, content} -> decode(expanded, content)
      {:error, :too_large} -> {:error, {:credentials_too_large, @max_bytes}}
      {:error, :enoent} -> {:ok, %__MODULE__{path: expanded, providers: %{}}}
      {:error, reason} -> {:error, {:credentials_read_failed, expanded, reason}}
    end
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

      Alto.Storage.with_lock(path <> ".lock", fn ->
        with {:ok, latest} <- load(path),
             :ok <-
               persist(%__MODULE__{
                 path: path,
                 providers: Map.update(latest.providers, provider, values, &Map.merge(&1, values))
               }) do
          {:ok,
           %__MODULE__{
             path: path,
             providers: Map.update(latest.providers, provider, values, &Map.merge(&1, values))
           }}
        end
      end)
    end
  end

  def put(_credentials, _provider, _values), do: {:error, :invalid_credentials_update}

  defp decode(path, content) do
    with {:ok, providers} <- decode_providers(content),
         :ok <- private_mode?(path) do
      {:ok, %__MODULE__{path: path, providers: providers}}
    end
  end

  defp decode_providers(content) do
    with {:ok, %{"version" => @version, "providers" => providers}} <- JSON.decode(content),
         true <- valid_providers?(providers) do
      {:ok, providers}
    else
      {:error, error} -> {:error, {:invalid_credentials_json, error}}
      _other -> {:error, :invalid_credentials_file}
    end
  end

  # A store that group or other can read is refused rather than trusted;
  # running setup again rewrites it with mode 0600.
  defp private_mode?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %{mode: _mode}} -> {:error, {:credentials_mode, path}}
      {:error, reason} -> {:error, {:credentials_read_failed, path, reason}}
    end
  end

  defp persist(%__MODULE__{} = credentials) do
    content = JSON.encode!(%{"version" => @version, "providers" => credentials.providers})

    if byte_size(content) > @max_bytes do
      {:error, {:credentials_too_large, @max_bytes}}
    else
      with :ok <- Alto.Storage.ensure_private_dir(Path.dirname(credentials.path), owned: true),
           :ok <- AtomicWrite.write(credentials.path, content <> "\n", 0o600) do
        :ok
      else
        {:error, reason} -> {:error, {:credentials_write_failed, credentials.path, reason}}
      end
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
        Enum.all?(values, fn {key, value} -> is_binary(key) and is_binary(value) end)
    end)
  end

  defp valid_providers?(_providers), do: false

  defp bounded_read(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case IO.binread(io, @max_bytes + 1) do
            {:error, _reason} -> {:error, :read_failed}
            :eof -> {:ok, <<>>}
            content when byte_size(content) > @max_bytes -> {:error, :too_large}
            content -> {:ok, content}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defimpl Inspect, for: Alto.Credentials do
  import Inspect.Algebra

  def inspect(credentials, _opts) do
    concat(["#Alto.Credentials<", credentials.path, ">"])
  end
end
