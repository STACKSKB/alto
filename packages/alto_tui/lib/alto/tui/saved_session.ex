defmodule Alto.TUI.SavedSession do
  @moduledoc "Disposable, incrementally replayed usage and child-activity projections."
  alias Alto.Session
  alias Alto.Usage
  alias Alto.TUI.Subagents
  @fields ~w(agent_id id parent session_id model backend status phase activity result)a
  @max_log 16_000_000

  def load(id, opts) do
    with :ok <- Session.validate_id(id) do
      path = Path.join([Session.dir(opts), ".cache", id <> ".activity.json"])
      prior = read_cache(path)
      log = Path.join(Session.dir(opts), id <> ".jsonl")

      with {:ok, next, offset, digest} <-
             Alto.Session.LogScan.fold(
               log,
               @max_log,
               prior["offset"],
               prior["digest"],
               prior,
               empty(),
               &replay(&1, &2, id)
             ) do
        next = %{next | "offset" => offset, "digest" => digest}

        if next != prior, do: Alto.Storage.write_json(path, next, 4_000_000)

        agents =
          next["runs"]
          |> Map.new(fn {_run, saved} ->
            agent = Map.new(@fields, &{&1, saved[Atom.to_string(&1)]})
            {agent.agent_id, Alto.Retained.detach(agent)}
          end)

        {:ok,
         %{usage: Usage.normalize(next["usage"]), agents: agents, truncated: next["truncated"]}}
      end
    end
  end

  defp empty,
    do: %{
      "v" => 4,
      "offset" => 0,
      "digest" => digest(""),
      "records" => 0,
      "usage" => stringify(Usage.new()),
      "accounting_runs" => %{},
      "runs" => %{},
      "truncated" => false
    }

  defp read_cache(path) do
    with {:ok, bytes} <- Alto.BoundedFile.read(path, 4_000_000),
         {:ok,
          %{
            "v" => 4,
            "offset" => offset,
            "records" => records,
            "usage" => usage,
            "accounting_runs" => accounting_runs,
            "runs" => runs,
            "truncated" => truncated,
            "digest" => digest
          } = state} <- JSON.decode(bytes),
         true <-
           is_integer(offset) and offset in 0..@max_log and is_integer(records) and
             records in 0..20_000,
         true <-
           is_boolean(truncated) and is_binary(digest) and is_map(usage) and is_map(runs) and
             map_size(runs) <= 256 and is_map(accounting_runs) and
             map_size(accounting_runs) <= 256 and
             Enum.all?(accounting_runs, fn {id, value} ->
               is_binary(id) and byte_size(id) <= 128 and value == true
             end),
         true <-
           Enum.all?(runs, fn {id, agent} -> is_binary(id) and valid_agent?(agent) end) do
      Alto.Retained.detach(state)
    else
      _ -> empty()
    end
  end

  defp valid_agent?(agent) when is_map(agent),
    do:
      Enum.all?(
        ~w(agent_id id status phase activity result),
        &(is_binary(agent[&1]) and byte_size(agent[&1]) <= 64_000)
      )

  defp valid_agent?(_), do: false

  defp replay(line, %{"records" => count} = state, id) do
    case JSON.decode(line) do
      {:ok, %{"v" => 1} = record} when count < 20_000 ->
        {:ok, %{state | "records" => count + 1} |> account(record) |> activity(record, id)}

      _ ->
        {:error, :saved_session_corrupt}
    end
  end

  defp account(
         state,
         %{
           "type" => "diagnostic",
           "event" => "provider_attempt_finished",
           "data" => %{"usage" => _} = data
         } =
           record
       ) do
    run_id = to_string(record["run_id"])

    if byte_size(run_id) <= 128 and
         (Map.has_key?(state["accounting_runs"], run_id) or
            map_size(state["accounting_runs"]) < 256) do
      state = %{state | "accounting_runs" => Map.put(state["accounting_runs"], run_id, true)}
      if is_map(data["usage"]), do: merge_usage(state, data["usage"]), else: state
    else
      %{state | "truncated" => true}
    end
  end

  defp account(state, %{"type" => "completed"} = record),
    do: %{
      state
      | "accounting_runs" => Map.delete(state["accounting_runs"], to_string(record["run_id"]))
    }

  defp account(state, %{"type" => "event", "event" => "model_completed"} = record) do
    case if(Map.has_key?(state["accounting_runs"], to_string(record["run_id"])),
           do: :accounted,
           else: Session.event_data(record)
         ) do
      {:ok, %{"usage" => usage}} when is_map(usage) -> merge_usage(state, usage)
      _ -> state
    end
  end

  defp account(state, _record), do: state

  defp merge_usage(state, usage),
    do: %{
      state
      | "usage" => stringify(Usage.merge(Usage.normalize(state["usage"]), Usage.normalize(usage)))
    }

  defp activity(state, %{"type" => "started", "subagent" => true} = record, id) do
    agent = Subagents.saved_agent(id, record) |> stringify() |> Alto.Retained.detach()

    runs =
      Map.reject(state["runs"], fn {_, value} -> value["agent_id"] == agent["agent_id"] end)

    if map_size(runs) < 256 do
      %{state | "runs" => Map.put(runs, to_string(record["run_id"]), agent)}
    else
      %{state | "truncated" => true}
    end
  end

  defp activity(state, record, _id) do
    key = to_string(record["run_id"])

    case Map.fetch(state["runs"], key) do
      {:ok, agent} ->
        agent =
          if record["type"] == "completed" do
            status = record["status"] || "unknown"

            %{
              agent
              | "status" => status,
                "phase" => status,
                "result" =>
                  Subagents.tail(
                    Subagents.saved_value(record["output"]) <>
                      "\n" <> Subagents.saved_value(record["reason"])
                  )
            }
          else
            %{
              agent
              | "activity" =>
                  Subagents.tail(agent["activity"] <> Subagents.saved_activity(record))
            }
          end

        %{state | "runs" => Map.put(state["runs"], key, agent)}

      :error ->
        state
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
