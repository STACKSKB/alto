defmodule Alto.Contrib do
  @moduledoc """
  Optional application policy and implementations for the Alto runtime.

  `configure/1` composes ordinary run options: project instruction discovery,
  transient retry policy, summary reduction and provider/model resolution.
  Hosts can override each callback, or call `Alto` directly with their own policy.
  """
  alias Alto.Contrib.Subagents.Models

  def run(task, opts \\ []), do: Alto.run(task, configure(opts))
  def start(task, opts \\ []), do: Alto.start(task, configure(opts))
  def resume(id, task, opts \\ []), do: Alto.resume(id, task, configure(opts))

  @doc "Compose application defaults without starting a run or discovering models."
  def configure(opts) do
    catalog = %{
      provider_profiles: opts[:provider_profiles],
      credentials_path: opts[:credentials_path]
    }

    opts
    |> Keyword.put_new(:retry_policy, &Alto.Contrib.Retry.Transient.decide/2)
    |> Keyword.put_new(:agent_prepare, fn prepared, context, options ->
      Models.prepare(prepared, Map.merge(catalog, context), options)
    end)
    |> Keyword.put_new(:agent_models, fn arguments, context, options ->
      Models.list(arguments, Map.merge(catalog, context), options)
    end)
    |> Keyword.put_new(:child_provider_resolver, fn key, model, context ->
      Models.provider(key, model, Map.merge(catalog, context))
    end)
    |> project_instructions()
    |> compaction()
  end

  defp project_instructions(opts) do
    case opts[:project_instructions] do
      :auto ->
        Keyword.put(opts, :project_instructions, &Alto.Contrib.Project.load/1)

      options when is_list(options) ->
        Keyword.put(opts, :project_instructions, &Alto.Contrib.Project.load(&1, options))

      _ ->
        opts
    end
  end

  defp compaction(opts) do
    case opts[:compaction] do
      true ->
        Keyword.put(opts, :compaction, strategy: Alto.Contrib.Context.Reducers.Summary)

      options when is_list(options) ->
        Keyword.put(
          opts,
          :compaction,
          Keyword.put_new(options, :strategy, Alto.Contrib.Context.Reducers.Summary)
        )

      _ ->
        opts
    end
  end
end
