defmodule Alto.Ingress.HMAC do
  @moduledoc "Generic HMAC-SHA256 verification for bounded HTTP ingress."

  @type headers :: [{String.t(), String.t()}]

  @doc "Verify a configured signature header over the exact request body."
  @spec verify(binary(), headers(), keyword()) :: :ok | {:error, term()}
  def verify(body, headers, opts) do
    with secret when is_binary(secret) and secret != "" and byte_size(secret) <= 65_536 <-
           Keyword.fetch!(opts, :secret),
         {:ok, signature} <-
           single_header(headers, String.downcase(Keyword.get(opts, :header, "x-signature"))) do
      expected =
        Keyword.get(opts, :prefix, "") <>
          encode(:crypto.mac(:hmac, :sha256, secret, body), Keyword.get(opts, :encoding, :base64))

      if Plug.Crypto.secure_compare(signature, expected), do: :ok, else: {:error, :bad_signature}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_hmac_secret}
    end
  end

  defp encode(digest, :base64), do: Base.encode64(digest)
  defp encode(digest, :hex), do: Base.encode16(digest, case: :lower)

  defp single_header(headers, name) do
    values = for {key, value} <- headers, String.downcase(key) == name, do: value

    case values do
      [value] when is_binary(value) and byte_size(value) <= 512 -> {:ok, value}
      [] -> {:error, :missing_signature}
      [_value] -> {:error, :signature_too_large}
      _many -> {:error, :duplicate_signature}
    end
  end
end
