defmodule Alto.Contrib.Listeners.WebAuth do
  @moduledoc """
  Replaceable authentication boundary for WebSocket upgrades.

  WebServer accepts `auth: :token` (a generated capability), `{:token, token}`,
  a unary function returning `:ok`, or explicit `:none` for a
  trusted transport. Authentication supplements the browser origin check.
  """

  def normalize(:token),
    do: normalize({:token, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)})

  def normalize({:token, token}) when is_binary(token) and byte_size(token) >= 32 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token),
      do: {:ok, {&authorize(&1, token), token}},
      else: {:error, :invalid_web_auth_token}
  end

  def normalize(:none), do: {:ok, {:none, nil}}

  def normalize({:token, _}), do: {:error, :invalid_web_auth_token}

  def normalize(auth) when is_function(auth, 1), do: {:ok, {auth, nil}}

  def normalize(_), do: {:error, :invalid_web_auth}

  def allowed?(_conn, :none), do: true

  def allowed?(conn, auth) do
    auth.(conn) == :ok
  catch
    _, _ -> false
  end

  defp authorize(conn, expected) do
    bearer_tokens =
      for "Bearer " <> token <- Plug.Conn.get_req_header(conn, "authorization"), do: token

    protocol_tokens =
      for header <- Plug.Conn.get_req_header(conn, "sec-websocket-protocol"),
          value <- String.split(header, ","),
          "alto-auth." <> token <- [String.trim(value)],
          do: token

    case bearer_tokens ++ protocol_tokens do
      [token] ->
        if Plug.Crypto.secure_compare(token, expected), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end
end
