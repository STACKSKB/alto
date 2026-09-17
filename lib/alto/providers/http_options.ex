defmodule Alto.Providers.HTTPOptions do
  @moduledoc false

  def stream_schema do
    [
      model: [type: {:custom, __MODULE__, :nonempty_string, []}, required: true],
      endpoint: [type: {:custom, __MODULE__, :endpoint, []}, required: true],
      timeout: [type: :pos_integer, default: 120_000],
      max_event_bytes: [type: :pos_integer, default: 1_000_000],
      max_response_bytes: [type: :pos_integer, default: 2_000_000],
      supports_images: [type: :boolean, default: false]
    ]
  end

  def validate(opts, schema, errors) do
    case NimbleOptions.validate(Keyword.take(opts, Keyword.keys(schema)), schema) do
      {:ok, values} ->
        {:ok, Map.new(values)}

      {:error, error} ->
        case Keyword.fetch!(errors, error.key) do
          {:value, tag} -> {:error, {tag, error.value}}
          reason -> {:error, reason}
        end
    end
  end

  def nonempty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  def nonempty_string(_), do: {:error, "expected a nonempty string"}

  def endpoint(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, value}

      _ ->
        {:error, "expected an HTTP(S) endpoint"}
    end
  end

  def endpoint(_), do: {:error, "expected an HTTP(S) endpoint"}
end
