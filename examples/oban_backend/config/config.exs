import Config

config :alto_oban_example,
  ecto_repos: [AltoObanExample.Repo]

config :alto_oban_example, AltoObanExample.Repo, pool_size: 10

config :alto_oban_example, Oban,
  repo: AltoObanExample.Repo,
  queues: [alto: 5]
