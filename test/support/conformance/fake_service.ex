defmodule Alto.Conformance.FakeService do
  @moduledoc "Deterministic authoritative commit log for runner failure conformance."

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  def commit(server \\ __MODULE__, key) do
    Agent.update(server, &Map.update(&1, key, 1, fn count -> count + 1 end))
    {:ok, %{key: inspect(key), applied: true}}
  end

  def committed?(server \\ __MODULE__, key), do: commit_count(server, key) > 0

  def commit_count(server \\ __MODULE__, key) do
    Agent.get(server, &Map.get(&1, key, 0))
  end
end
