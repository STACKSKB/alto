defmodule AltoObanExample.Repo do
  use Ecto.Repo,
    otp_app: :alto_oban_example,
    adapter: Ecto.Adapters.Postgres
end
