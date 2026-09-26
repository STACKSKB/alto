defmodule Alto.Runner.Execution.Children do
  @moduledoc """
  Child admission, inherited authority, journals, and result accounting.

  Operations return the supplied execution map with only their owned fields
  changed; validation helpers accept minimal maps containing the fields used.
  """
  alias Alto.{Event, Usage}
  alias Alto.Runner.{Budget, Result}
  alias Alto.Subagents.Continuation
  alias Alto.Subagents.Policy, as: ChildPolicy
  alias Alto.Runner.Execution.{Events, Operation}

  @spawn_schema NimbleOptions.new!(
                  id: [type: :string, required: true],
                  task: [type: :any, required: true],
                  max_steps: [type: {:or, [nil, :pos_integer]}, default: nil],
                  tools: [type: {:or, [{:in, [:inherit]}, {:list, :any}]}, default: :inherit],
                  loop: [type: {:or, [nil, {:struct, Alto.Loop.Spec}]}, default: nil],
                  model: [type: {:or, [nil, :string]}, default: nil],
                  profile_key: [type: {:or, [nil, :string]}, default: nil],
                  system_prompt: [type: {:or, [nil, :string]}, default: nil],
                  model_tools: [type: {:or, [nil, {:list, :any}]}, default: nil]
                )

  @inherited_options ~w(provider_profiles credentials_path provider_retries retry_policy tool_presenter checkpoint_version
                        parent_expires_at_ms approval continuation_store
                        max_approval_details_bytes max_tool_result_bytes max_transcript_bytes
                        max_events session_dir)a

  defp validate_spawn(data) when is_map(data) and not is_struct(data) do
    with true <- Enum.all?(Map.keys(data), &is_atom/1),
         {:ok, values} <- NimbleOptions.validate(Map.to_list(data), @spawn_schema),
         spec <- Map.new(values),
         :ok <- validate_spawn_constraints(spec) do
      {:ok, spec}
    else
      false ->
        {:error, :spawn_fields_must_be_atoms}

      {:error, %NimbleOptions.ValidationError{key: key, value: value}} ->
        {:error, {:invalid_spawn_field, key, value}}

      {:error, _} = error ->
        error
    end
  end

  defp validate_spawn(data), do: {:error, {:not_a_map, data}}

  # Tasks intentionally accept any term except nil and the empty binary. The
  # selected child loop owns the task shape.
  defp validate_spawn_constraints(spec) do
    cond do
      spec.id == "" ->
        {:error, {:invalid_spawn_field, :id, spec.id}}

      is_nil(spec.task) or spec.task == "" ->
        {:error, {:invalid_spawn_field, :task, spec.task}}

      is_binary(spec.model) and byte_size(spec.model) not in 1..256 ->
        {:error, {:invalid_spawn_field, :model, spec.model}}

      is_binary(spec.profile_key) and byte_size(spec.profile_key) not in 1..256 ->
        {:error, {:invalid_spawn_field, :profile_key, spec.profile_key}}

      is_binary(spec.system_prompt) and byte_size(spec.system_prompt) not in 1..64_000 ->
        {:error, {:invalid_spawn_field, :system_prompt, spec.system_prompt}}

      is_list(spec.model_tools) and
          not Enum.all?(spec.model_tools, &(is_atom(&1) or (is_binary(&1) and &1 != ""))) ->
        {:error, {:invalid_spawn_field, :model_tools, spec.model_tools}}

      true ->
        :ok
    end
  end

  def run_children(specs, concurrency, run) do
    with {:ok, specs, journal, run} <- prepare_children(specs, run) do
      run_prepared_children(specs, concurrency, journal, run)
    end
  end

  @doc "Prepare resources and journal without granting any child dispatch."
  def prepare_children(specs, run) do
    with {:ok, specs} <- prepare_resources(specs, run),
         {:ok, journal, run} <- open_continuation(specs, run),
         do: {:ok, specs, journal, run}
  end

  @doc "Execute an already prepared batch; callers may persist its parent first."
  def run_prepared_children(specs, concurrency, journal, run) do
    {status, outcomes} =
      run_batch(specs, concurrency, &dispatch_subagent(&1, run, journal), run)

    case durable_call(fn -> finish_child_journal(journal, outcomes) end, run) do
      :ok ->
        {:ok, status, outcomes, journal, run}

      {:error, {:child_pending, _, state}} when state in ["suspended", "decided", "resuming"] ->
        {:ok, status, outcomes, journal, run}

      {:error, reason} ->
        run =
          run
          |> Events.merge_verdict(:unknown)
          |> Events.add_persistence_error({:subagent_journal, reason})

        if status == :ok do
          run =
            Enum.reduce(outcomes, run, fn {id, outcome}, acc ->
              merge_child_summary(acc, child_summary(id, outcome))
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
    with {:ok, {values, run}} <-
           Alto.Result.reduce(results, {[], run}, fn {id, data}, {values, acc} ->
             with :ok <- validate_child_summary(id, data),
                  do:
                    {:ok, {[public_child_summary(data) | values], merge_child_summary(acc, data)}}
           end) do
      {:ok, Enum.reverse(values), run}
    end
  end

  defp validate_child_summary(id, %{id: id, status: status} = data)
       when status in [:ok, :error, :cancelled] do
    if Map.has_key?(data, :usage) do
      with true <- Usage.valid?(data.usage),
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
        :ok
      else
        _ -> {:error, :invalid_retained_child_result}
      end
    else
      if status == :error and Map.has_key?(data, :error),
        do: :ok,
        else: {:error, :invalid_retained_child_result}
    end
  end

  defp validate_child_summary(_, _), do: {:error, :invalid_retained_child_result}
  defp valid_persistence?(value) when value in [:ok, :not_requested], do: true
  defp valid_persistence?({:degraded, errors}) when is_list(errors), do: true
  defp valid_persistence?(_), do: false

  def open_continuation(specs, run, parent \\ nil)

  def open_continuation(_specs, %{continuation_store: nil} = run, nil), do: {:ok, nil, run}

  def open_continuation(specs, run, parent) do
    {key, run} = Operation.next(run)
    open_reserved_continuation(specs, run, parent, key)
  end

  def open_reserved_continuation(specs, run, parent, key) do
    metadata = %{
      "parent_run_id" => run.tool_context.session_id,
      "parent_session_id" => run.session,
      "agent_identity" => Alto.Protocol.encode_term(run.agent_identity)
    }

    with {:ok, journal} <-
           durable_call(
             fn ->
               Continuation.open(
                 run.continuation_store,
                 "children:" <> key,
                 Enum.map(specs, & &1.id),
                 metadata,
                 parent: parent,
                 deadline: run.budget.deadline
               )
             end,
             run
           ) do
      event =
        Event.durable(:subagents_started, %{
          ids: Enum.map(specs, & &1.id),
          journal: Continuation.identity(journal)
        })

      {:ok, journal, Events.record(run, event)}
    end
  end

  defp dispatch_subagent(spec, run, nil), do: start_subagent(spec, run)

  defp dispatch_subagent(spec, run, journal) do
    with {:ok, ticket} <- durable_call(fn -> Continuation.dispatch(journal, spec.id) end, run) do
      case start_subagent(Map.put(spec, :subagent_ticket, ticket), run) do
        {:ok, _} = started ->
          started

        {:error, reason} = error ->
          case Continuation.complete(ticket, child_summary(spec.id, error)) do
            {:ok, _} ->
              error

            {:error, storage_reason} ->
              {:error, {:subagent_journal_failed, reason, storage_reason}}
          end
      end
    end
  end

  def retain_child_outcome(nil, outcome), do: outcome

  def retain_child_outcome(
        _ticket,
        {:error, _, %{checkpoint: %{"kind" => "child", "ungranted" => true}}} = outcome
      ),
      do: outcome

  def retain_child_outcome(%Continuation.Ticket{} = ticket, outcome) do
    data = child_summary(ticket.id, outcome)
    result = elem(outcome, tuple_size(outcome) - 1)

    stored =
      case outcome do
        {:error, :approval_suspended, %{checkpoint: %{"kind" => "child"} = checkpoint}} ->
          Continuation.suspend(ticket, checkpoint, result.workspace)

        _ ->
          Continuation.complete(ticket, data)
      end

    case stored do
      {:ok, _} ->
        outcome

      {:error, reason} ->
        errors = Result.persistence_errors(result) ++ [{:subagent_journal, reason}]

        {:error, {:subagent_journal_failed, reason},
         %{result | verdict: :unknown, persistence: Result.persistence_status(errors)}}
    end
  end

  defp finish_child_journal(nil, _outcomes), do: :ok

  defp finish_child_journal(journal, outcomes) do
    with {:ok, _} <-
           Alto.Result.reduce(outcomes, nil, fn
             {id, {:error, {:not_started, _}} = outcome}, _ ->
               Continuation.skip(journal, id, child_summary(id, outcome))

             _, last ->
               {:ok, last}
           end),
         {:ok, _} <- Continuation.join(journal),
         do: :ok
  end

  def with_journal(data, nil), do: data
  def with_journal(data, journal), do: Map.put(data, :journal, Continuation.identity(journal))

  def prepare_resources(specs, %{workspaces: nil}), do: {:ok, specs}

  def prepare_resources(specs, run) do
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
  def start_subagent(spec, run) do
    with {:ok, [spec]} <- register_agents([spec], run) do
      result =
        with {:ok, provider} <- resolve_child_provider(spec, run) do
          if is_nil(provider) and is_nil(spec.loop) do
            {:error, :provider_required}
          else
            sub_opts = child_options(spec, run, provider)

            with {:ok, sub_opts} <- resumed_options(sub_opts, Map.get(spec, :resume_data), run),
                 do: Alto.Runner.start(spec.task, Keyword.put(sub_opts, :runner, run.runner))
          end
        end

      if match?({:error, _}, result), do: Alto.Messaging.close(spec.messaging)
      result
    end
  end

  def register_agents(specs, run) do
    options =
      specs
      |> Enum.reject(&Map.has_key?(&1, :messaging))
      |> Enum.map(fn spec ->
        [label: spec.id, parent: run.messaging.id, supported: spec.profile_key != "codex"]
      end)

    with {:ok, senders} <- Alto.Messaging.register_many(run.messaging.router, options) do
      {specs, []} =
        Enum.map_reduce(specs, senders, fn spec, remaining ->
          case spec do
            %{messaging: _} ->
              {spec, remaining}

            _ ->
              [sender | remaining] = remaining
              {Map.put(spec, :messaging, sender), remaining}
          end
        end)

      {:ok, specs}
    end
  end

  defp child_prompt(spec, prompt_config) do
    prompt_opts =
      prompt_config
      |> Keyword.take([:prompt, :project_instructions])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if spec.system_prompt do
      Keyword.put(prompt_opts, :prompt, spec.system_prompt)
    else
      prompt_opts
    end
  end

  defp child_options(spec, run, provider) do
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
    inherited = run |> Map.take(@inherited_options) |> Map.to_list()

    sub_opts =
      inherited ++
        [
          provider: provider,
          child_profile: checkpoint_profile(spec),
          tools: subagent_tools(spec.tools, run),
          loop: spec.loop || Alto.default_loop()
        ] ++
        child_prompt(spec, run.prompt_config) ++
        [
          cwd: run.tool_context.cwd,
          workspace_assignment: Map.get(spec, :workspace_assignment),
          parent_workspaces: run.workspaces,
          subagent_ticket: Map.get(spec, :subagent_ticket),
          tool_context_metadata: run.tool_context.metadata,
          budget: run.budget,
          budget_account: run.budget.account,
          max_effects: run.budget.max_effects,
          max_model_requests: run.budget.max_model_requests,
          run_timeout: Budget.remaining(run.budget),
          owner: run.execution_owner,
          messaging: spec.messaging,
          agent_scheduler: Map.get(spec, :agent_scheduler),
          parent_max_agent_depth: run.max_agent_depth,
          max_steps: min(spec.max_steps || run.max_steps, run.max_steps),
          provider_timeout: Budget.timeout(run.budget, run.provider_timeout),
          tool_timeout: Budget.timeout(run.budget, run.tool_timeout),
          approval_timeout: Budget.timeout(run.budget, run.approval_timeout),
          event_sink: subagent_sink(run, spec.id),
          parent_run_id: run.tool_context.session_id,
          agent_identity: child_agent_identity(run.tool_context.agent_identity, spec.id),
          parent_model_tools: run.model_tools,
          agent_depth: run.agent_depth + 1
        ] ++ child_session_options(run)

    case spec.model_tools do
      nil -> sub_opts
      names -> Keyword.put(sub_opts, :model_tools, names)
    end
  end

  # The retained profile contains only the trusted resolver key, never provider
  # configuration or credentials.
  defp checkpoint_profile(spec),
    do:
      Map.drop(spec, [
        :workspace_assignment,
        :subagent_ticket,
        :resume_data,
        :messaging,
        :agent_scheduler
      ])

  defp resolve_child_provider(%{profile_key: key, model: model}, run)
       when is_binary(key) and is_binary(model) do
    resolve_provider(fn -> Alto.Subagents.Models.provider(key, model, run) end, run)
  end

  defp resolve_child_provider(%{profile_key: nil}, run), do: {:ok, run.provider}

  defp resolve_child_provider(%{profile_key: key}, run) when is_binary(key) do
    case resolve_named_provider(key, run) do
      {:ok, nil} -> {:ok, run.provider}
      result -> result
    end
  end

  defp resolve_named_provider(key, run) do
    resolve_provider(
      fn ->
        driver = run.spec.driver

        if function_exported?(driver, :resolve_child_provider, 2),
          do: driver.resolve_child_provider(key, run.spec),
          else: {:error, :child_provider_resolver_required}
      end,
      run
    )
  end

  defp resolve_provider(resolve, run) do
    case Alto.Runner.Execution.Call.run(
           resolve,
           Budget.timeout(run.budget, 30_000),
           run.cancel_ref
         ) do
      {:ok, {:ok, provider}} ->
        Alto.Runner.Execution.Setup.normalize_provider(provider)

      {:ok, {:error, _} = error} ->
        error

      {:cancelled, reason} ->
        send(self(), {:alto_cancel, run.cancel_ref, reason})
        {:error, {:cancelled, reason}}

      _ ->
        {:error, :child_provider_resolution_failed}
    end
  end

  @doc "Resume only explicitly decided retained children using current inherited parent capabilities."
  def resume_decided(journal, run) do
    with {:ok, entries} <- durable_call(fn -> Continuation.suspended(journal) end, run) do
      decided = Enum.filter(entries, &(&1.state == :decided))

      {status, _outcomes} =
        run_batch(decided, run.child_limits.max_concurrency, &resume_child(&1, journal, run), run)

      # Each child retains its terminal outcome before collection. A failed
      # start or losing grant leaves the durable entry parked for inspection.
      status
    end
  end

  defp run_batch(specs, concurrency, start, run) do
    Alto.Runner.SubagentBatch.run(specs, concurrency, start, fn ->
      case {Alto.Runner.Execution.Call.cancellation(run.cancel_ref), Budget.check(run.budget)} do
        {{:cancelled, _} = cancelled, _} -> cancelled
        {_, {:error, _} = error} -> error
        _ -> :continue
      end
    end)
  end

  defp resume_child(entry, journal, run) do
    with {:ok, binding} <- Alto.Runner.Checkpoint.child_binding(entry.checkpoint),
         {:ok, spec} <- validate_spawn(binding.profile),
         :ok <- validate_subagent_tools(spec.tools, run),
         true <- spec.id == entry.id,
         {:ok, handle} <-
           start_subagent(Map.put(spec, :resume_data, {journal, entry, binding}), run) do
      {:ok, handle}
    else
      false -> {:error, :child_profile_mismatch}
      {:error, _} = error -> error
    end
  end

  defp resumed_options(opts, nil, _run), do: {:ok, opts}

  defp resumed_options(opts, {journal, entry, binding}, run) do
    ticket = Continuation.resume_ticket(journal, entry.identity)
    decision = if entry.decision == "approve", do: :approve, else: :deny

    opts =
      opts
      |> Keyword.delete(:workspace_assignment)
      |> Keyword.merge(
        checkpoint: {entry.checkpoint, decision},
        child_resume: entry.identity,
        subagent_ticket: ticket,
        session: entry.checkpoint["session_id"],
        resume_snapshot: binding.resume_snapshot,
        cwd: binding.cwd,
        agent_depth: binding.agent_depth,
        parent_expires_at_ms: binding.expires_at_ms
      )

    case entry.workspace do
      nil ->
        {:ok, opts}

      %{id: id, revision: revision, status: "worked"} when not is_nil(run.workspaces) ->
        {:ok, Keyword.put(opts, :workspace_resume, {run.workspaces, id, revision})}

      _ ->
        {:error, :child_workspace_mismatch}
    end
  end

  defp child_session_options(%{session: nil}), do: [session: nil, resume_snapshot: false]

  defp child_session_options(%{child_limits: %{sessions: :separate}} = run),
    do: [session: :new, resume_snapshot: true, parent_session_id: run.session]

  defp child_session_options(run),
    do: [session: run.session, resume_snapshot: false, parent_session_id: run.session]

  defp subagent_tools(:inherit, run), do: run.tool_specs
  defp subagent_tools(tools, _run), do: tools

  defp subagent_sink(run, id) do
    fn event ->
      if event.domain == :live do
        Alto.Events.notify(
          run.event_sink,
          Event.live(:subagent_progress, %{id: id, event: event})
        )
      end

      :ok
    end
  end

  @doc "Remove journal-only accounting details from a child summary delivered to its loop."
  def public_child_summary(summary), do: Map.delete(summary, :persistence)

  def child_summary(id, {:ok, result}),
    do: Map.merge(child_fields(id, result), %{status: :ok})

  def child_summary(id, {:error, {:cancelled, reason}, result}),
    do: Map.merge(child_fields(id, result), %{status: :cancelled, reason: reason})

  def child_summary(id, {:error, reason, result}),
    do: Map.merge(child_fields(id, result), %{status: :error, error: reason})

  def child_summary(id, {:error, reason}), do: %{id: id, status: :error, error: reason}

  defp child_fields(id, result) do
    result
    |> Map.take(~w(output model_requests usage persistence run_id session_id workspace)a)
    |> Map.merge(%{id: id, outcome: result.verdict})
  end

  def merge_child_summary(run, %{error: {:run_process_failed, _}}),
    do: Events.merge_verdict(run, :unknown)

  def merge_child_summary(run, %{usage: usage, outcome: outcome} = summary) do
    run = Events.merge_verdict(run, outcome)
    run = %{run | usage: Usage.merge(run.usage, struct(Usage, usage))}

    Enum.reduce(
      Result.persistence_errors(summary),
      run,
      &Events.add_persistence_error(&2, {:subagent, &1})
    )
  end

  def merge_child_summary(run, _summary), do: run

  defp validate_subagent_tools(:inherit, _run), do: :ok

  defp validate_subagent_tools(tools, run) do
    inherited = Enum.map(run.tool_specs, &canonical_tool/1)

    if Enum.all?(tools, &(canonical_tool(&1) in inherited)),
      do: :ok,
      else: {:error, :tool_scope_exceeded}
  end

  defp canonical_tool(module) when is_atom(module), do: {module, []}
  defp canonical_tool(spec), do: spec

  defp admit(run, agents) do
    case Alto.Runner.Execution.Call.run(
           fn -> ChildPolicy.admit(run.spec.subagents, agents, %{depth: run.agent_depth}) end,
           Budget.timeout(run.budget, run.tool_timeout),
           run.cancel_ref
         ) do
      {:ok, result} -> result
      {:cancelled, reason} -> {:cancelled, reason}
      {:error, reason} -> {:error, {:subagent_policy_failed, reason}}
    end
  end

  def validate_batch(%{agents: agents}, run) when is_list(agents) do
    case run.child_limits do
      %{max_children: max, max_concurrency: concurrency}
      when max in 1..64 and concurrency in 1..max//1 ->
        cond do
          run.agent_depth >= run.max_agent_depth ->
            {:error, :max_depth_exceeded}

          agents == [] or length(agents) > max ->
            {:error, :max_children_exceeded}

          true ->
            with :ok <- admit(run, agents),
                 do: validate_batch_specs(agents, run, concurrency)
        end

      _ ->
        {:error, :invalid_subagent_policy}
    end
  end

  def validate_batch(_data, _run), do: {:error, :invalid_agents}

  defp validate_batch_specs(agents, run, concurrency) do
    with {:ok, specs} <-
           Alto.Result.reduce(agents, [], fn request, specs ->
             with {:ok, spec} <- validate_spawn(request),
                  :ok <- validate_subagent_tools(spec.tools, run),
                  false <- Enum.any?(specs, &(&1.id == spec.id)) do
               {:ok, [spec | specs]}
             else
               true -> {:error, :duplicate_child_id}
               {:error, _} = error -> error
             end
           end) do
      {:ok, Enum.reverse(specs), concurrency}
    end
  end

  defp child_agent_identity(%{root_run_id: id, path: path}, child),
    do: %{root_run_id: id, path: path ++ [child]}

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
