defmodule Alto.Ingress.HMAC do
  @moduledoc "Generic HMAC-SHA256 verification for bounded HTTP ingress."

  @type headers :: [{String.t(), String.t()}]

  @doc "Verify a configured signature header over the exact request body."
  @spec verify(binary(), headers(), keyword()) :: :ok | {:error, term()}
  def verify(body, headers, opts) when is_binary(body) and is_list(headers) and is_list(opts) do
    with {:ok, secret} <- secret(opts),
         {:ok, header} <- header(opts),
         {:ok, encoding} <- encoding(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, signature} <- single_header(headers, header),
         expected <- prefix <> encode(:crypto.mac(:hmac, :sha256, secret, body), encoding),
         :ok <- secure_compare(signature, expected) do
      :ok
    end
  end

  def verify(_body, _headers, _opts), do: {:error, :invalid_hmac_arguments}

  defp secret(opts) do
    case Keyword.get(opts, :secret) do
      value when is_binary(value) and value != "" and byte_size(value) <= 65_536 -> {:ok, value}
      _other -> {:error, :invalid_hmac_secret}
    end
  end

  defp header(opts) do
    case Keyword.get(opts, :header, "x-signature") do
      value when is_binary(value) and value != "" and byte_size(value) <= 256 ->
        {:ok, String.downcase(value)}

      _other ->
        {:error, :invalid_hmac_header}
    end
  end

  defp encoding(opts) do
    case Keyword.get(opts, :encoding, :base64) do
      encoding when encoding in [:base64, :hex] -> {:ok, encoding}
      _other -> {:error, :invalid_hmac_encoding}
    end
  end

  defp prefix(opts) do
    case Keyword.get(opts, :prefix, "") do
      value when is_binary(value) and byte_size(value) <= 256 -> {:ok, value}
      _other -> {:error, :invalid_hmac_prefix}
    end
  end

  defp encode(digest, :base64), do: Base.encode64(digest)
  defp encode(digest, :hex), do: Base.encode16(digest, case: :lower)

  defp single_header(headers, name) do
    values =
      headers
      |> Enum.filter(fn {key, _value} -> String.downcase(key) == name end)
      |> Enum.map(&elem(&1, 1))

    case values do
      [value] when is_binary(value) and byte_size(value) <= 512 -> {:ok, value}
      [] -> {:error, :missing_signature}
      [_value] -> {:error, :signature_too_large}
      _many -> {:error, :duplicate_signature}
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    if Plug.Crypto.secure_compare(left, right), do: :ok, else: {:error, :bad_signature}
  end

  defp secure_compare(_left, _right), do: {:error, :bad_signature}
end
