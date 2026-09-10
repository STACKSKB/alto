defmodule Alto.Ingress.IdentityHeader do
  @moduledoc "Explicit, bounded delivery identity extraction from one HTTP header."

  @max_identity_bytes 200

  @spec extract([{String.t(), String.t()}], keyword()) :: {:ok, String.t()} | {:error, term()}
  def extract(headers, opts) when is_list(headers) and is_list(opts) do
    case Keyword.get(opts, :header, "x-delivery-id") do
      header when is_binary(header) and header != "" and byte_size(header) <= 256 ->
        values =
          headers
          |> Enum.filter(fn {key, _value} -> String.downcase(key) == String.downcase(header) end)
          |> Enum.map(&elem(&1, 1))

        case values do
          [id] when is_binary(id) and id != "" and byte_size(id) <= @max_identity_bytes ->
            if String.contains?(id, [<<0>>, "\n", "\r"]),
              do: {:error, :invalid_delivery_id},
              else: {:ok, id}

          [id] when is_binary(id) and id != "" ->
            {:error, :delivery_id_too_large}

          [] ->
            {:error, :missing_delivery_id}

          _many ->
            {:error, :duplicate_delivery_id}
        end

      _other ->
        {:error, :invalid_identity_header}
    end
  end

  def extract(_headers, _opts), do: {:error, :invalid_identity_arguments}
end
