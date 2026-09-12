defmodule Alto.Runner.Execution.Children do
  @moduledoc "Reusable child admission, inherited authority, journals, and result accounting."
  alias Alto.{Event, Usage}
  alias Alto.Runner.Budget
  alias Alto.Subagents.Journal
  alias Alto.Subagents.Bounded, as: BoundedSubagents
  alias Alto.Runner.Execution.Events

  @fields [
    :runner,
    :runner_options,
    :provider,
    :tool_specs,
    :approval,
    :budget,
    :cancel_ref,
    :tool_context,
    :subagent_journal,
    :workspaces,
    :session,
    :session_dir,
    :agent_identity,
    :op_seq,
    :prompt_config,
    :max_steps,
    :max_agent_depth,
    :agent_depth,
    :model_tools,
    :provider_timeout,
    :tool_timeout,
    :approval_timeout,
    :max_approval_details_bytes,
    :max_tool_result_bytes,
    :max_transcript_bytes,
    :max_events,
    :event_sink,
    :usage
  ]
  defmodule State do
    @moduledoc "Parent authority and child lifecycle services, independent of its scheduler."
    defstruct [
      :runner,
      :runner_options,
      :provider,
      :tool_specs,
      :approval,
      :budget,
      :cancel_ref,
      :tool_context,
      :subagent_journal,
      :workspaces,
      :session,
      :session_dir,
      :agent_identity,
      :op_seq,
      :prompt_config,
      :max_steps,
      :max_agent_depth,
      :agent_depth,
      :model_tools,
      :provider_timeout,
      :tool_timeout,
      :approval_timeout,
      :max_approval_details_bytes,
      :max_tool_result_bytes,
      :max_transcript_bytes,
      :max_events,
      :event_sink,
      :usage,
      :policy,
      :events
    ]
  end

  @doc false
  def project(run),
    do:
      struct!(
        State,
        Map.take(run, @fields)
        |> Map.put(:policy, run.spec.subagents)
        |> Map.put(:events, Events.project(run))
      )

  @doc false
  def merge(run, %State{} = state),
    do: run |> Map.merge(Map.take(state, @fields)) |> Events.merge(state.events)

  def validate_spawn(data) when is_map(data) do
    with {:ok, id} <- spawn_field(data, [:id, "id"], :binary),
         {:ok, task} <- spawn_task(data),
         {:ok, max_steps} <- spawn_optional(data, [:max_steps, "max_steps"], :positive),
         {:ok, tools} <- spawn_optional(data, [:tools, "tools"], :tools),
         {:ok, loop} <- spawn_optional(data, [:loop, "loop"], :loop),
         {:ok, provider} <- spawn_optional(data, [:provider, "provider"], :provider),
         {:ok, system_prompt} <- spawn_optional(data, [:system_prompt, "system_prompt"], :text),
         {:ok, model_tools} <-
           spawn_optional(data, [:model_tools, "model_tools"], :model_tools) do
      {:ok,
       %{
         id: id,
         task: task,
         max_steps: max_steps,
         tools: tools,
         loop: loop,
         provider: provider,
         system_prompt: system_prompt,
         model_tools: model_tools
       }}
    end
  end

  def validate_spawn(data), do: {:error, {:not_a_map, data}}

  defp spawn_field(data, keys, :binary) do
    value = Enum.find_value(keys, fn key -> Map.get(data, key) end)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  # A delegated task is any non-empty term: rule loops take lists and maps,
  # model loops take strings. The child loop decides what it accepts.
  defp spawn_task(data) do
    value = Map.get(data, :task, Map.get(data, "task"))

    if is_nil(value) or value == "" do
      {:error, {:invalid_spawn_field, [:task, "task"], value}}
    else
      {:ok, value}
    end
  end

  defp spawn_optional(data, keys, :positive) do
    case Enum.find_value(keys, fn key -> Map.get(data, key) end) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  defp spawn_optional(data, keys, :tools) do
    case Enum.find_value(keys, fn key -> Map.get(data, key) end) do
      nil -> {:ok, :inherit}
      :inherit -> {:ok, :inherit}
      tools when is_list(tools) -> {:ok, tools}
      value -> {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  defp spawn_optional(data, keys, :loop) do
    case Enum.find_value(keys, fn key -> Map.get(data, key) end) do
      nil -> {:ok, nil}
      %Alto.Loop.Spec{} = spec -> {:ok, spec}
      value -> {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  defp spawn_optional(data, keys, :model_tools) do
    case Enum.find_value(keys, fn key -> Map.get(data, key) end) do
      nil ->
        {:ok, nil}

      names when is_list(names) ->
        if Enum.all?(names, &(is_atom(&1) or (is_binary(&1) and &1 != ""))) do
          {:ok, names}
        else
          {:error, {:invalid_spawn_field, keys, names}}
        end

      value ->
        {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  defp spawn_optional(data, keys, :text) do
    case Enum.find_value(keys, &Map.get(data, &1)) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) in 1..64_000 -> {:ok, value}
      value -> {:error, {:invalid_spawn_field, keys, value}}
    end
  end

  defp spawn_optional(data, keys, :provider) do
    case Enum.find_value(keys, fn key -> Map.get(data, key) end) do
      nil ->
        {:ok, nil}

      provider ->
        case normalize_provider(provider, []) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, {:invalid_spawn_field, keys, reason}}
        end
    end
  end

  def run_children(specs, concurrency, run) do
    with {:ok, specs, journal, run} <- prepare_children(specs, run) do
      run_prepared_children(specs, concurrency, journal, run)
    end
  end

  @doc "Prepare resources and journal without granting any child dispatch."
  def prepare_children(specs, run) do
    with {:ok, specs} <- prepare_subagent_workspaces(specs, run),
         {:ok, journal, run} <- open_child_journal(specs, run),
         do: {:ok, specs, journal, run}
  end

  @doc "Execute an already prepared batch; callers may persist its parent first."
  def run_prepared_children(specs, concurrency, journal, run) do
    {status, outcomes} =
      Alto.Runner.SubagentBatch.run(
        specs,
        concurrency,
        &dispatch_subagent(&1, run, journal),
        fn ->
          case {cancellation(run.cancel_ref), Budget.check(run.budget)} do
            {{:cancelled, _} = cancelled, _} -> cancelled
            {_, {:error, _} = error} -> error
            _ -> :continue
          end
        end
      )

    case durable_call(fn -> finish_child_journal(journal, outcomes) end, run) do
      :ok ->
        {:ok, status, outcomes, journal, run}

      {:error, reason} ->
        run =
          run |> merge_verdict(:unknown) |> add_persistence_error({:subagent_journal, reason})

        if status == :ok do
          run =
            Enum.reduce(outcomes, run, fn {_, outcome}, acc ->
              merge_child_result(acc, outcome)
            end)

          {:error, {:subagent_journal_failed, reason}, run}
        else
          # Cancellation/timeout is still the parent disposition. Preserve
          # unresolved dispatch evidence instead of claiming a joined result.
          {:ok, status, outcomes, journal, run}
        end
    end
  end

  @doc "Validate and merge retained native child summaries without redispatch."
  def merge_retained(results, run) when is_list(results) do
    Enum.reduce_while(results, {:ok, [], run}, fn {id, data}, {:ok, values, acc} ->
      case retained_outcome(id, data) do
        {:ok, outcome} ->
          {:cont,
           {:ok, [Map.delete(data, :persistence) | values], merge_child_result(acc, outcome)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, values, run} -> {:ok, Enum.reverse(values), run}
      error -> error
    end
  end

  defp retained_outcome(id, %{id: id, status: status} = data)
       when status in [:ok, :error, :cancelled] do
    if Map.has_key?(data, :usage) do
      usage = data.usage
      fields = Map.keys(Usage.to_map(Usage.new()))

      with true <- is_map(usage) and Enum.sort(Map.keys(usage)) == Enum.sort(fields),
           true <- Enum.all?(usage, fn {_, value} -> is_integer(value) and value >= 0 end),
           true <-
             data[:outcome] in [
               :empty,
               :completed,
               :rejected_before_dispatch,
               :failed_known,
               :unknown
             ],
           true <- is_integer(data[:model_requests]) and data.model_requests >= 0,
           true <- valid_persistence?(Map.get(data, :persistence, :ok)) do
        result = %{
          Alto.Runner.Result.empty()
          | usage: usage,
            verdict: data.outcome,
            persistence: Map.get(data, :persistence, :ok)
        }

        {:ok,
         if(status == :ok,
           do: {:ok, result},
           else: {:error, data[:error] || data[:reason], result}
         )}
      else
        _ -> {:error, :invalid_retained_child_result}
      end
    else
      if status == :error and Map.has_key?(data, :error),
        do: {:ok, {:error, data.error}},
        else: {:error, :invalid_retained_child_result}
    end
  end

  defp retained_outcome(_, _), do: {:error, :invalid_retained_child_result}
  defp valid_persistence?(value) when value in [:ok, :not_requested], do: true
  defp valid_persistence?({:degraded, errors}) when is_list(errors), do: true
  defp valid_persistence?(_), do: false

  defp open_child_journal(_specs, %{subagent_journal: nil} = run), do: {:ok, nil, run}

  defp open_child_journal(specs, run) do
    {key, run} = next_operation(run)

    metadata = %{
      "parent_run_id" => run.tool_context.session_id,
      "parent_session_id" => run.session,
      "agent_identity" => Alto.Protocol.encode_term(run.agent_identity)
    }

    with {:ok, journal} <-
           durable_call(
             fn ->
               Journal.open(
                 run.subagent_journal,
                 "children:" <> key,
                 Enum.map(specs, & &1.id),
                 metadata,
                 deadline: run.budget.deadline
               )
             end,
             run
           ) do
      event =
        Event.durable(:subagents_started, %{
          ids: Enum.map(specs, & &1.id),
          journal: Journal.identity(journal)
        })

      {:ok, journal, record_event(run, event)}
    end
  end

  defp dispatch_subagent(spec, run, nil), do: start_subagent(spec, run)

  defp dispatch_subagent(spec, run, journal) do
    with {:ok, ticket} <- durable_call(fn -> Journal.dispatch(journal, spec.id) end, run) do
      case start_subagent(Map.put(spec, :subagent_ticket, ticket), run) do
        {:ok, _} = started ->
          started

        {:error, reason} = error ->
          case Journal.complete(ticket, subagent_data(spec.id, error)) do
            {:ok, _} ->
              error

            {:error, storage_reason} ->
              {:error, {:subagent_journal_failed, reason, storage_reason}}
          end
      end
    end
  end

  def retain_child_outcome(nil, outcome), do: outcome

  def retain_child_outcome(%Journal.Ticket{} = ticket, outcome) do
    data = subagent_data(ticket.id, outcome)
    result = elem(outcome, tuple_size(outcome) - 1)
    retained = Map.put(data, :persistence, result.persistence)

    case Journal.complete(ticket, retained) do
      {:ok, _} ->
        outcome

      {:error, reason} ->
        errors = existing_persistence_errors(result) ++ [{:subagent_journal, reason}]

        {:error, {:subagent_journal_failed, reason},
         %{result | verdict: :unknown, persistence: persistence_status(errors)}}
    end
  end

  defp finish_child_journal(nil, _outcomes), do: :ok

  defp finish_child_journal(journal, outcomes) do
    skipped =
      Enum.reduce_while(outcomes, :ok, fn
        {id, {:error, {:not_started, _}} = outcome}, :ok ->
          case Journal.skip(journal, id, subagent_data(id, outcome)) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end

        _, :ok ->
          {:cont, :ok}
      end)

    with :ok <- skipped, {:ok, _} <- Journal.join(journal), do: :ok
  end

  def with_journal(data, nil), do: data
  def with_journal(data, journal), do: Map.put(data, :journal, Journal.identity(journal))

  def configured_subagent_journal(%BoundedSubagents{journal: journal}), do: journal
  def configured_subagent_journal(_), do: nil

  def configured_workspaces(%BoundedSubagents{workspaces: manager}), do: manager
  def configured_workspaces(_), do: nil

  defp prepare_subagent_workspaces(specs, %{workspaces: nil}), do: {:ok, specs}

  defp prepare_subagent_workspaces(specs, run) do
    with {:ok, snapshot} <-
           Alto.Runner.Execution.Workspace.call(
             fn -> Alto.Workspaces.prepare(run.workspaces, run.tool_context.cwd) end,
             run.budget,
             run.tool_timeout,
             run.cancel_ref
           ) do
      {:ok,
       Enum.map(specs, fn spec ->
         identity = child_agent_identity(run.tool_context.agent_identity, spec.id)
         Map.put(spec, :workspace_assignment, {run.workspaces, snapshot, identity})
       end)}
    end
  end

  # Resource setup/capture are bounded, cancellable operations. Worker execution
  # stays in this owned run process, holding the resource lock until it returns.
  defp start_subagent(spec, run) do
    provider = spec.provider || run.provider

    if is_nil(provider) and is_nil(spec.loop) do
      {:error, :provider_required}
    else
      # Nil prompt options are dropped, not inherited: an explicit nil would
      # read as "present" to prompt resolution and conflict where absence is
      # the neutral value. Absence and explicit nil resolve identically.
      prompt_opts =
        run.prompt_config
        |> Keyword.take([:prompt, :system_prompt, :project_instructions])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      prompt_opts =
        if spec.system_prompt do
          prompt_opts
          |> Keyword.drop([:prompt, :system_prompt])
          |> Keyword.put(:system_prompt, spec.system_prompt)
        else
          prompt_opts
        end

      # A delegated task defaults to a fresh default loop: the parent's
      # driver expects the parent's task shape, which the child task rarely
      # shares. Recursive policies pass their own spec explicitly.
      # Model exposure is inherited with no widening: the parent's
      # effective subset is carried down and intersected with the child's
      # inherited or narrowed capabilities. A child with `model_tools: nil`
      # (absent) requests all of its resolved tools; an explicit list
      # (including `[]`) narrows further. Native `invoke_tool` still uses
      # full runtime capabilities; only provider-originated `run_tool`
      # calls are exposure-checked.
      sub_opts =
        [
          provider: provider,
          runner_options: run.runner_options,
          tools: subagent_tools(spec.tools, run),
          approval: run.approval,
          loop: spec.loop || Alto.default_loop()
        ] ++
          prompt_opts ++
          [
            cwd: run.tool_context.cwd,
            workspace_assignment: Map.get(spec, :workspace_assignment),
            parent_workspaces: run.workspaces,
            parent_subagent_journal: run.subagent_journal,
            subagent_ticket: Map.get(spec, :subagent_ticket),
            tool_context_metadata: run.tool_context.metadata,
            budget: run.budget,
            owner: self(),
            parent_max_agent_depth: run.max_agent_depth,
            max_steps: min(spec.max_steps || run.max_steps, run.max_steps),
            provider_timeout: Budget.timeout(run.budget, run.provider_timeout),
            tool_timeout: Budget.timeout(run.budget, run.tool_timeout),
            approval_timeout: Budget.timeout(run.budget, run.approval_timeout),
            max_approval_details_bytes: run.max_approval_details_bytes,
            max_tool_result_bytes: run.max_tool_result_bytes,
            max_transcript_bytes: run.max_transcript_bytes,
            max_events: run.max_events,
            event_sink: subagent_sink(run, spec.id),
            session_dir: run.session_dir,
            parent_run_id: run.tool_context.session_id,
            agent_identity: child_agent_identity(run.tool_context.agent_identity, spec.id),
            parent_model_tools: run.model_tools,
            agent_depth: run.agent_depth + 1
          ] ++ child_session_options(run)

      sub_opts =
        case spec.model_tools do
          nil -> sub_opts
          names -> Keyword.put(sub_opts, :model_tools, names)
        end

      Alto.Runner.start(spec.task, Keyword.put(sub_opts, :runner, run.runner))
    end
  end

  defp child_session_options(%{session: nil}), do: [session: nil, resume_snapshot: false]

  defp child_session_options(%{policy: %BoundedSubagents{sessions: :separate}} = run),
    do: [session: :new, resume_snapshot: true, parent_session_id: run.session]

  defp child_session_options(run),
    do: [session: run.session, resume_snapshot: false, parent_session_id: run.session]

  defp subagent_tools(:inherit, run), do: run.tool_specs
  defp subagent_tools(tools, _run), do: tools

  defp subagent_sink(run, id) do
    fn event ->
      if event.domain == :live do
        notify(run.event_sink, Event.live(:subagent_progress, %{id: id, event: event}))
      end

      :ok
    end
  end

  def subagent_data(id, {:ok, result}),
    do: Map.merge(child_fields(id, result), %{status: :ok})

  def subagent_data(id, {:error, {:cancelled, reason}, result}),
    do: Map.merge(child_fields(id, result), %{status: :cancelled, reason: reason})

  def subagent_data(id, {:error, reason, result}),
    do: Map.merge(child_fields(id, result), %{status: :error, error: reason})

  def subagent_data(id, {:error, reason}), do: %{id: id, status: :error, error: reason}

  defp child_fields(id, result) do
    %{
      id: id,
      output: result.output,
      model_requests: result.model_requests,
      usage: result.usage,
      outcome: result.verdict,
      run_id: result.run_id,
      session_id: result.session_id,
      workspace: result.workspace
    }
  end

  def merge_child_result(run, {:error, {:run_process_failed, _}, _}),
    do: merge_verdict(run, :unknown)

  def merge_child_result(run, {:error, {:run_process_failed, _}}),
    do: merge_verdict(run, :unknown)

  def merge_child_result(run, {:error, _reason, result}),
    do: merge_child_result(run, {:ok, result})

  def merge_child_result(run, {:ok, result}) do
    run = merge_verdict(run, result.verdict)
    run = %{run | usage: Usage.merge(run.usage, struct(Usage, result.usage))}

    Enum.reduce(
      existing_persistence_errors(result),
      run,
      &add_persistence_error(&2, {:subagent, &1})
    )
  end

  def merge_child_result(run, _outcome), do: run

  def validate_subagent_tools(:inherit, _run), do: :ok

  def validate_subagent_tools(tools, run) do
    inherited = Enum.map(run.tool_specs, &canonical_tool/1)

    if Enum.all?(tools, &(canonical_tool(&1) in inherited)),
      do: :ok,
      else: {:error, :tool_scope_exceeded}
  end

  defp canonical_tool(module) when is_atom(module), do: {module, []}
  defp canonical_tool(spec), do: spec

  def validate_batch(%{agents: agents}, run) when is_list(agents) do
    case run.policy do
      %BoundedSubagents{max_children: max, max_concurrency: concurrency}
      when max in 1..64 and concurrency in 1..max//1 ->
        cond do
          run.agent_depth >= run.max_agent_depth -> {:error, :max_depth_exceeded}
          agents == [] or length(agents) > max -> {:error, :max_children_exceeded}
          true -> validate_batch_specs(agents, run, concurrency)
        end

      _ ->
        {:error, :invalid_subagent_policy}
    end
  end

  def validate_batch(_data, _run), do: {:error, :invalid_agents}

  defp validate_batch_specs(agents, run, concurrency) do
    Enum.reduce_while(agents, {:ok, []}, fn request, {:ok, specs} ->
      with {:ok, spec} <- validate_spawn(request),
           :ok <- validate_subagent_tools(spec.tools, run),
           false <- Enum.any?(specs, &(&1.id == spec.id)) do
        {:cont, {:ok, [spec | specs]}}
      else
        true -> {:halt, {:error, :duplicate_child_id}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs), concurrency}
      error -> error
    end
  end

  def subagent_failed(id, reason) do
    Event.durable(:subagent_failed, %{id: id, error: reason})
  end

  defp normalize_provider(provider, opts),
    do: Alto.Runner.Execution.Setup.normalize_provider(provider, opts)

  defp next_operation(run) do
    seq = run.op_seq + 1
    {"#{run.tool_context.session_id}:op-#{seq}", %{run | op_seq: seq}}
  end

  defp child_agent_identity(%{root_run_id: id, path: path}, child),
    do: %{root_run_id: id, path: path ++ [child]}

  defp notify(sink, event), do: Alto.Runner.Execution.Support.notify(sink, event)
  defp cancellation(ref), do: Alto.Runner.Execution.Call.cancellation(ref)
  defp record_event(run, event), do: %{run | events: Events.record(run.events, event)}
  defp merge_verdict(run, verdict), do: %{run | events: Events.merge_verdict(run.events, verdict)}

  defp add_persistence_error(run, reason),
    do: %{run | events: Events.add_persistence_error(run.events, reason)}

  defp existing_persistence_errors(%{persistence: {:degraded, errors}}), do: errors
  defp existing_persistence_errors(_), do: []
  defp persistence_status([]), do: :ok
  defp persistence_status(errors), do: {:degraded, errors}

  defp durable_call(fun, run) do
    case Alto.Runner.Execution.Call.run(fun, Budget.remaining(run.budget), run.cancel_ref) do
      {:ok, value} ->
        value

      {:error, reason} ->
        {:error, {:subagent_journal_outcome_unknown, reason}}

      {:cancelled, reason} ->
        send(self(), {:alto_cancel, run.cancel_ref, reason})
        {:error, {:cancelled, reason}}
    end
  end
end
