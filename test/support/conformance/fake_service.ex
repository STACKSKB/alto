defmodule Alto.Conformance.FakeService do
  @moduledoc """
  Deterministic fake external service for failure conformance.

  Stands in for the spoke behind a connector (ticket update, artifact
  publisher, notification service): the authoritative participant whose commit log
  decides whether an effect applied. The harness never infers commit from
  its own timeouts — only this log does.

  Scripted failure points per key (set with `set_script/3`):

    * `:ok` — record one commit, answer success;
    * `:fail_known` — answer `{:error, :downstream_rejected}` with no commit
      (the participant says it did not commit; trusts that signal);
    * `:commit_then_timeout` — record the commit, then sleep past the
      caller's deadline so the runner classifies `:unknown`;
    * `:commit_then_crash` — record the commit, then exit (also `:unknown`);
    * `:block` — never reply (models a stalled downstream; the caller times
      out as `:unknown`).

  This module chooses no retry, classification, or compensation policy: it
  only commits and answers. Recovery policy lives in the consumer/ledger
  contract under test.
  """

  use Agent

  @type mode :: :ok | :fail_known | :commit_then_timeout | :commit_then_crash | :block

  @doc "Start a fake service. `:name` registers it; state is empty."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{scripts: %{}, commits: %{}, log: []} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc "Script the failure mode for `key` (default `:ok`)."
  @spec set_script(GenServer.server(), term(), mode()) :: :ok
  def set_script(server \\ __MODULE__, key, mode)
      when mode in [:ok, :fail_known, :commit_then_timeout, :commit_then_crash, :block] do
    Agent.update(server, &%{&1 | scripts: Map.put(&1.scripts, key, mode)})
  end

  @doc """
  Call the service for `key`. Records a commit for every mode except
  `:fail_known`, then behaves per the script.
  """
  @spec call(GenServer.server(), term(), term()) :: {:ok, map()} | {:error, term()}
  def call(server \\ __MODULE__, key, _payload \\ %{}) do
    mode = Agent.get(server, &Map.get(&1.scripts, key, :ok))

    case mode do
      :ok ->
        commit(server, key)
        {:ok, %{key: inspect(key), applied: true}}

      :fail_known ->
        {:error, :downstream_rejected}

      :commit_then_timeout ->
        commit(server, key)
        Process.sleep(10_000)
        {:ok, %{key: inspect(key), applied: true}}

      :commit_then_crash ->
        commit(server, key)
        exit(:boom_after_commit)

      :block ->
        commit(server, key)

        receive do
          :never -> {:ok, %{}}
        end
    end
  end

  @doc "True when `key` committed at least once."
  @spec committed?(GenServer.server(), term()) :: boolean()
  def committed?(server \\ __MODULE__, key) do
    Agent.get(server, &Map.get(&1.commits, key, 0)) > 0
  end

  @doc "Number of recorded commits for `key`."
  @spec commit_count(GenServer.server(), term()) :: non_neg_integer()
  def commit_count(server \\ __MODULE__, key) do
    Agent.get(server, &Map.get(&1.commits, key, 0))
  end

  @doc "Total commits across all keys."
  @spec total_commits(GenServer.server()) :: non_neg_integer()
  def total_commits(server \\ __MODULE__) do
    Agent.get(server, fn state -> state.commits |> Map.values() |> Enum.sum() end)
  end

  @doc "Reset scripts, commits, and the log."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    Agent.update(server, fn _ -> %{scripts: %{}, commits: %{}, log: []} end)
  end

  defp commit(server, key) do
    Agent.update(server, fn state ->
      %{state | commits: Map.update(state.commits, key, 1, &(&1 + 1)), log: [key | state.log]}
    end)
  end
end
