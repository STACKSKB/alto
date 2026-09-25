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

  def endpoint_options(opts, base_url, path, key \\ :endpoint) do
    endpoint =
      Keyword.get_lazy(opts, key, fn ->
        String.trim_trailing(Keyword.get(opts, :base_url, base_url), "/") <> path
      end)

    Keyword.put(opts, :endpoint, endpoint)
  end

  def validate(opts, schema) do
    with {:ok, values} <- NimbleOptions.validate(Keyword.take(opts, Keyword.keys(schema)), schema) do
      {:ok, Map.new(values)}
    end
  end

  def request_options(config, headers, extra) do
    # Provider extensions cannot override the streaming and timeout guards.
    Keyword.merge(
      config.req_options,
      extra ++
        [
          url: config.endpoint,
          headers: headers,
          raw: true,
          retry: false,
          receive_timeout: config.timeout,
          request_timeout: config.timeout
        ]
    )
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
