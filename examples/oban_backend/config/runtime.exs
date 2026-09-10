import Config

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://postgres:postgres@localhost/alto_oban_example_dev"

config :alto_oban_example, AltoObanExample.Repo, url: database_url
