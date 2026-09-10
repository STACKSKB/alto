defmodule AltoObanExample.InboxDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:delivery_hash, :binary, autogenerate: false}
  @derive {Inspect, except: [:payload_hash]}
  schema "alto_inbox_deliveries" do
    field(:delivery_key, :string)
    field(:payload_hash, :binary)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(delivery_key, payload) do
    params = %{
      delivery_hash: :crypto.hash(:sha256, delivery_key),
      delivery_key: delivery_key,
      payload_hash: payload |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    }

    %__MODULE__{}
    |> cast(params, [:delivery_hash, :delivery_key, :payload_hash])
    |> validate_required([:delivery_hash, :delivery_key, :payload_hash])
    |> unique_constraint(:delivery_hash, name: :alto_inbox_deliveries_pkey)
  end
end
