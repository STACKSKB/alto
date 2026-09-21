defmodule Alto.Listeners.WebAuth do
  @moduledoc """
  Replaceable authentication boundary for WebSocket upgrades.

  WebServer accepts `auth: :token` (a generated capability), `{:token, token}`,
  `{module, options}` implementing this callback, or explicit `:none` for a
  trusted transport. Authentication supplements the browser origin check.
  """

  @callback authorize(Plug.Conn.t(), keyword()) :: :ok | {:error, term()}

  def normalize(:token),
    do: normalize({:token, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)})

  def normalize({:token, token}) when is_binary(token) and byte_size(token) >= 32 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token),
      do: {:ok, {{__MODULE__, token: token}, token}},
      else: {:error, :invalid_web_auth_token}
  end

  def normalize(:none), do: {:ok, {:none, nil}}

  def normalize({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) and Alto.Capabilities.implements?(module, __MODULE__),
      do: {:ok, {{module, opts}, nil}},
      else: {:error, :invalid_web_auth}
  end

  def normalize(_), do: {:error, :invalid_web_auth}

  def allowed?(_conn, :none), do: true

  def allowed?(conn, {module, opts}) do
    module.authorize(conn, opts) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def authorize(conn, opts) do
    expected = Keyword.fetch!(opts, :token)

    candidates =
      Enum.flat_map(Plug.Conn.get_req_header(conn, "authorization"), fn
        "Bearer " <> token -> [token]
        _ -> []
      end) ++
        (Plug.Conn.get_req_header(conn, "sec-websocket-protocol")
         |> Enum.flat_map(&String.split(&1, ","))
         |> Enum.flat_map(fn value ->
           case String.trim(value) do
             "alto-auth." <> token -> [token]
             _ -> []
           end
         end))

    case candidates do
      [token] ->
        if Plug.Crypto.secure_compare(token, expected), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end
end
