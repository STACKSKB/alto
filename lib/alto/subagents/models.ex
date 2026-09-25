defmodule Alto.Subagents.Models do
  @moduledoc false
  alias Alto.Harness.ProviderProfile

  def validate_policy!(:all), do: :ok

  def validate_policy!(models) when is_map(models) do
    if Enum.all?(models, fn {backend, ids} ->
         is_binary(backend) and backend != "" and is_list(ids) and
           Enum.all?(ids, &(is_binary(&1) and &1 != ""))
       end),
       do: :ok,
       else: raise(ArgumentError, "expected backend IDs mapped to model ID lists")
  end

  def validate_policy!(_),
    do: raise(ArgumentError, "models must be :all or a map of backend IDs to model ID lists")

  defp allowed?(:all, _, _), do: true
  defp allowed?(models, backend, model), do: model in Map.get(models, backend, [])

  defp backends(run) do
    with {:ok, profiles} <-
           ProviderProfile.from_run_options(
             provider: run.provider,
             provider_profiles: run.provider_profiles
           ) do
      native = Map.new(profiles, &{&1.id, &1})

      case Map.get(run.tools, "codex_agent") do
        %{module: Alto.Tools.CodexAgent, opts: opts} ->
          if Map.has_key?(native, "codex"),
            do: {:error, :duplicate_agent_backend},
            else: {:ok, Map.put(native, "codex", {:codex, opts})}

        _ ->
          {:ok, native}
      end
    end
  end

  def prepare(%{agents: agents}, run, opts) do
    policy = Keyword.get(opts, :models, :all)
    validate_policy!(policy)

    with {:ok, backends} <- backends(run),
         {:ok, agents} <-
           Alto.Result.traverse(agents, fn agent ->
             cond do
               not Map.has_key?(backends, agent.profile_key) ->
                 {:error, {:unknown_agent_backend, agent.profile_key}}

               not allowed?(policy, agent.profile_key, agent.model) ->
                 {:error, {:agent_model_not_allowed, agent.profile_key, agent.model}}

               true ->
                 {:ok, child(agent, Map.fetch!(backends, agent.profile_key))}
             end
           end),
         do: {:ok, %{agents: agents}}
  end

  defp child(agent, {:codex, opts}) do
    Map.merge(agent, %{
      task: %{"task" => agent.task, "model" => agent.model},
      loop: Alto.rule_loop(steps: ["codex_agent"]),
      tools: [{Alto.Tools.CodexAgent, opts}],
      model_tools: []
    })
  end

  defp child(agent, _profile), do: agent

  def provider(key, model, run) do
    with {:ok, backends} <- backends(run) do
      case Map.fetch(backends, key) do
        {:ok, {:codex, _}} ->
          {:ok, nil}

        {:ok, profile} ->
          {:ok, ProviderProfile.runtime_provider(profile, model, credentials(run))}

        :error ->
          {:error, {:unknown_agent_backend, key}}
      end
    end
  end

  def list(arguments, run, opts) do
    policy = Keyword.get(opts, :models, :all)
    validate_policy!(policy)

    with {:ok, backends} <- backends(run) do
      selected =
        Enum.filter(backends, fn {id, _} ->
          (not Map.has_key?(arguments, "backend") or arguments["backend"] == id) and
            (policy == :all or Map.has_key?(policy, id))
        end)
        |> Enum.sort_by(&elem(&1, 0))

      {models, errors} =
        Enum.reduce(selected, {[], []}, fn {id, backend}, {models, errors} ->
          case discover(backend, id, policy, run) do
            {:ok, entries} ->
              entries =
                Enum.flat_map(entries, fn entry ->
                  model = entry[:id]

                  if is_binary(model) and allowed?(policy, id, model),
                    do: [%{backend: id, model: model, name: entry[:name] || model}],
                    else: []
                end)

              {models ++ entries, errors}

            {:error, _} ->
              {models, errors ++ [%{backend: id, error: "model discovery failed"}]}
          end
        end)

      query = String.downcase(Map.get(arguments, "query", ""))

      models =
        models
        |> Enum.filter(&String.contains?(String.downcase(&1.model <> " " <> &1.name), query))
        |> Enum.sort_by(&{&1.backend, &1.model})

      offset = Map.get(arguments, "offset", 0)
      limit = Map.get(arguments, "limit", 50)

      {:ok,
       %{
         models: Enum.slice(models, offset, limit),
         backends: Enum.map(selected, &elem(&1, 0)),
         errors: errors,
         next_offset: if(offset + limit < length(models), do: offset + limit, else: nil)
       }}
    end
  end

  defp discover(_backend, id, policy, _run) when is_map(policy),
    do: {:ok, Enum.map(Map.fetch!(policy, id), &%{id: &1})}

  defp discover({:codex, opts}, _id, :all, run),
    do: Alto.Tools.CodexAgent.models(run.tool_context, opts)

  defp discover(profile, _id, :all, run), do: ProviderProfile.models(profile, credentials(run))

  defp credentials(%{credentials_path: nil}), do: []
  defp credentials(run), do: [credentials_path: run.credentials_path]
end
