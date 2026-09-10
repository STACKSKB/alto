defmodule AltoObanExample.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AltoObanExample.Repo,
      {Oban, Application.fetch_env!(:alto_oban_example, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AltoObanExample.Supervisor)
  end
end
