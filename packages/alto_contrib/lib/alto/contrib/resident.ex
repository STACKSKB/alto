defmodule Alto.Contrib.Resident do
  @moduledoc """
  Optional resident task host composed from Alto execution and durable stores.

  Trusted profiles select workflow and authority. Clients select profile names,
  task text and revision-fenced decisions; they never supply execution options.
  Use `resident: [workspace: ..., state_dir: ..., profiles: ...]` in `alto.exs`
  with `alto --serve`, or supervise `Resident.Service` directly.
  """

  alias Alto.Contrib.Resident.{Config, Service}

  def start(options, opts \\ []), do: Service.start(Config.new(options), opts)
end
