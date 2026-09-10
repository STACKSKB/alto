defmodule AltoObanExample.Inbox do
  @moduledoc "An Oban-backed durable implementation of `Alto.Inbox`."

  @behaviour Alto.Inbox

  alias AltoObanExample.InboxDelivery

  @required_options [:repo, :oban, :worker, :run]

  @impl true
  def validate_options(opts) do
    missing = Enum.reject(@required_options, &Keyword.has_key?(opts, &1))

    cond do
      missing != [] -> {:error, {:missing_inbox_options, missing}}
      not module_with?(opts[:repo], :transaction, 2) -> {:error, :invalid_repo}
      is_nil(opts[:oban]) -> {:error, :invalid_oban_name}
      not module_with?(opts[:worker], :new, 2) -> {:error, :invalid_worker}
      not is_binary(opts[:run]) or opts[:run] == "" -> {:error, :invalid_run}
      true -> :ok
    end
  end

  @impl true
  def admit(delivery_key, payload, opts) do
    repo = Keyword.fetch!(opts, :repo)
    oban = Keyword.fetch!(opts, :oban)
    worker = Keyword.fetch!(opts, :worker)
    run = Keyword.fetch!(opts, :run)

    args = %{
      "delivery_key" => delivery_key,
      "run" => run,
      "payload" => payload
    }

    # The delivery row and Oban job commit together. The row supplies permanent
    # source-id dedup independently of Oban's configurable pruning window.
    job =
      worker.new(args,
        queue: :alto,
        unique: [period: :infinity, fields: [:worker, :args], keys: [:delivery_key]]
      )

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:delivery, InboxDelivery.changeset(delivery_key, payload))
      |> then(&Oban.insert(oban, &1, :job, job))

    case repo.transaction(multi) do
      {:ok, %{job: %Oban.Job{conflict?: true}}} ->
        {:error, :duplicate}

      {:ok, %{job: job}} ->
        {:ok, job}

      {:error, :delivery, %Ecto.Changeset{} = changeset, _changes} ->
        if duplicate?(changeset), do: {:error, :duplicate}, else: {:error, changeset}

      {:error, operation, reason, _changes} ->
        {:error, {:transaction_failed, operation, reason}}
    end
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn
      {:delivery_hash, {_message, metadata}} -> metadata[:constraint] == :unique
      _other -> false
    end)
  end

  defp module_with?(module, function, arity) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_with?(_module, _function, _arity), do: false
end
