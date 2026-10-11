defmodule Alto.Contrib.Resident.Loops.Team do
  @moduledoc "Planner and named-worker delegation followed by Alto's default integration loop."
  @behaviour Alto.Loop

  alias Alto.Event
  alias Alto.Loops.Default

  @impl true
  def init(task, _spec) do
    state = %{phase: :planning, task: task, inner: nil}

    {:continue, state,
     [{:request_model, %{model_tools: [], context_message: stage_message("planning")}}]}
  end

  @impl true
  def handle_event(%Event{type: :model_completed, data: data}, %{phase: :planning} = state, spec) do
    with [] <- Map.get(data, :tool_calls, []),
         {:ok, plan} <- decode_plan(Map.get(data, :message)),
         {:ok, agents} <- translate(plan, spec.driver_options) do
      {:continue, %{state | phase: :children}, [{:spawn_agents, %{agents: agents}}]}
    else
      _ -> {{:error, :invalid_team_plan}, state, []}
    end
  end

  def handle_event(%Event{type: :subagents_completed}, %{phase: :children} = state, spec) do
    {terminal, inner, [{:request_model, data}]} = Default.init(state.task, spec)
    request = {:request_model, Map.put(data, :context_message, stage_message("integrating"))}
    {terminal, %{state | phase: :integrating, inner: inner}, [request]}
  end

  def handle_event(event, %{phase: :integrating} = state, spec) do
    {terminal, inner, effects} = Default.handle_event(event, state.inner, spec)
    {terminal, %{state | inner: inner}, effects}
  end

  def handle_event(event, state, _spec),
    do: {{:error, {:unexpected_team_event, event.type, state.phase}}, state, []}

  @impl true
  def dump_checkpoint(%{phase: :children, task: task, inner: nil}, _spec),
    do: {:ok, %{phase: :children, task: task, inner: nil}}

  def dump_checkpoint(%{phase: :integrating, task: task, inner: inner}, spec) do
    with {:ok, encoded} <- Default.dump_checkpoint(inner, spec),
         do: {:ok, %{phase: :integrating, task: task, inner: encoded}}
  end

  def dump_checkpoint(_state, _spec), do: {:error, :team_checkpoint_unavailable}

  @impl true
  def load_checkpoint(%{phase: :children, task: task, inner: nil} = checkpoint, _spec)
      when map_size(checkpoint) == 3,
      do: {:ok, %{phase: :children, task: task, inner: nil}}

  def load_checkpoint(%{phase: :integrating, task: task, inner: encoded} = checkpoint, spec)
      when map_size(checkpoint) == 3 do
    with {:ok, inner} <- Default.load_checkpoint(encoded, spec),
         do: {:ok, %{phase: :integrating, task: task, inner: inner}}
  end

  def load_checkpoint(_checkpoint, _spec), do: {:error, :invalid_team_checkpoint}

  @doc "Resolve a saved worker name from the current trusted profile."
  @impl true
  def resolve_child_provider(profile, spec) do
    case Map.fetch(Keyword.fetch!(spec.driver_options, :workers), profile) do
      {:ok, options} -> {:ok, Keyword.get(options, :provider)}
      :error -> {:error, :unknown_profile}
    end
  end

  defp decode_plan(message) when is_binary(message) and byte_size(message) <= 1_000_000 do
    case JSON.decode(message) do
      {:ok, %{"agents" => agents} = plan} when map_size(plan) == 1 and is_list(agents) ->
        {:ok, agents}

      _ ->
        {:error, :invalid_plan}
    end
  end

  defp decode_plan(_), do: {:error, :invalid_plan}

  defp translate(agents, opts) do
    max = Keyword.fetch!(opts, :max_children)
    workers = Keyword.fetch!(opts, :workers)

    if length(agents) in 1..max do
      Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
        case translate_one(agent, workers) do
          {:ok, child} ->
            if Enum.any?(acc, &(&1.id == child.id)),
              do: {:halt, {:error, :duplicate_id}},
              else: {:cont, {:ok, [child | acc]}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, children} -> {:ok, Enum.reverse(children)}
        error -> error
      end
    else
      {:error, :invalid_child_count}
    end
  end

  defp translate_one(%{"id" => id, "profile" => profile, "task" => task} = agent, workers)
       when map_size(agent) == 3 and is_binary(id) and byte_size(id) in 1..100 and
              is_binary(profile) and is_binary(task) and byte_size(task) in 1..32_000 do
    case Map.fetch(workers, profile) do
      {:ok, options} ->
        {:ok,
         Map.merge(Map.new(Keyword.delete(options, :provider)), %{
           id: id,
           task: task,
           profile_key: profile
         })}

      :error ->
        {:error, :unknown_profile}
    end
  end

  defp translate_one(_, _), do: {:error, :invalid_agent}

  defp stage_message(stage), do: JSON.encode!(%{type: "alto_resident_team_stage", stage: stage})
end
