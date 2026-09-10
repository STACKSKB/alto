defmodule AltoObanExample.Repo.Migrations.InstallObanAndInbox do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    create table(:alto_inbox_deliveries, primary_key: false) do
      add(:delivery_hash, :binary, primary_key: true)
      add(:delivery_key, :text, null: false)
      add(:payload_hash, :binary, null: false)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  def down do
    drop(table(:alto_inbox_deliveries))
    Oban.Migration.down()
  end
end
