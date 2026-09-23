defmodule Alto.Runner.Execution.Setup do
  @moduledoc "Build validated execution capabilities from trusted run options."
  alias Alto.{Session, Usage}
  alias Alto.Tool.Context
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget
  require Logger

  @limits_options [
    max_steps: [type: :pos_integer, default: 32],
    provider_timeout: [type: :pos_integer, default: 125_000],
    tool_timeout: [type: :pos_integer, default: 125_000],
    approval_timeout: [type: :pos_integer, default: 300_000],
    max_approval_details_bytes: [type: :pos_integer, default: 64_000],
    max_tool_result_bytes: [type: :pos_integer, default: 64_000],
    max_transcript_bytes: [type: :pos_integer, default: 8_000_000],
    max_events: [type: :pos_integer, default: 1_000],
    provider_retries: [type: :non_neg_integer, default: 0],
    agent_depth: [type: :non_neg_integer, default: 0],
    resume_snapshot: [type: :boolean, default: true],
    session_history: [type: {:in, [:completed, :settled]}, default: :completed],
    max_conversation_bytes: [type: :pos_integer, default: 128_000_000]
  ]
  @limits_schema NimbleOptions.new!(@limits_options)

  def open(task, opts) do
    spec = Keyword.get(opts, :loop, Alto.default_loop())

    provider = normalize_provider(Keyword.get(opts, :provider))

    tools = Keyword.get(opts, :tools, [])
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()
    approval = normalize_approval(Keyword.get(opts, :approval, Alto.Approvals.DenyAll))

    with {:ok, limits} <- limits(opts),
         :ok <- validate_spec(spec),
         :ok <- Alto.Context.Policy.validate(spec.context),
         :ok <- Alto.Retry.validate(Keyword.get(opts, :retry_policy)),
         :ok <- Alto.ToolPresentation.validate(Keyword.get(opts, :tool_presenter)),
         {:ok, budget} <- resolve_budget(opts),
         {:ok, child_limits} <-
           resolve_child_policy(
             spec.subagents,
             budget,
             limits.tool_timeout,
             Keyword.get(opts, :cancel_ref)
           ),
         {:ok, provider} <- provider,
         {:ok, approval} <- approval,
         :ok <- validate_directory(cwd),
         {:ok, compaction} <- normalize_compaction(Keyword.get(opts, :compaction, false)),
         :ok <- validate_session_dir(Keyword.get(opts, :session_dir)),
         {:ok, tool_map, definitions} <- Alto.Tool.Registry.build(tools),
         {:ok, definitions, model_exposure} <-
           Alto.Tool.Registry.expose(
             definitions,
             tool_map,
             Keyword.get(opts, :model_tools),
             Keyword.get(opts, :parent_model_tools)
           ),
         {:ok, messages_rev, transcript_bytes} <-
           init_transcript(task, opts, cwd, tools, provider, limits.max_transcript_bytes),
         {:ok, run} <-
           build_run(
             Map.merge(limits, %{
               spec: spec,
               compaction: compaction,
               child_limits: child_limits,
               provider: provider,
               tools: tool_map,
               tool_definitions: definitions,
               approval: approval,
               messages_rev: messages_rev,
               transcript_bytes: transcript_bytes,
               model_tools: model_exposure,
               budget: budget
             }),
             cwd,
             opts
           ) do
      persist_start(run, opts, task)
    end
  end

  defp limits(opts) do
    case NimbleOptions.validate(
           Keyword.take(opts, Keyword.keys(@limits_options)),
           @limits_schema
         ) do
      {:ok, values} ->
        {:ok, Map.new(values)}

      {:error, %NimbleOptions.ValidationError{key: key, value: value}} ->
        {:error, {:invalid_option, key, value}}
    end
  end

  defp build_run(settings, cwd, opts) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_run_id/0)

    agent_identity =
      case Keyword.get(opts, :agent_identity) do
        nil -> %{root_run_id: session_id, path: []}
        identity -> identity
      end

    initial = %{
      loop_state: nil,
      runner: Keyword.get(opts, :runner, Alto.Runner.default()),
      input: Keyword.get(opts, :input),
      resolved_operations: [],
      history_digest: nil,
      resume_context_observation:
        Map.get(Keyword.get(opts, :resume) || %{}, :context_observation),
      checkpoint_version: Keyword.get(opts, :checkpoint_version),
      subagent_ticket: Keyword.get(opts, :subagent_ticket),
      child_profile: Keyword.get(opts, :child_profile),
      child_resume: Keyword.get(opts, :child_resume),
      parent_expires_at_ms: Keyword.get(opts, :parent_expires_at_ms),
      continuation_store: Keyword.get(opts, :continuation_store),
      checkpoint_resume:
        not is_nil(Keyword.get(opts, :checkpoint)) or not is_nil(Keyword.get(opts, :continuation)),
      tool_context: %Context{
        session_id: session_id,
        cwd: cwd,
        metadata: Keyword.get(opts, :tool_context_metadata, %{}),
        agent_identity: agent_identity
      },
      model_requests: 0,
      usage: Usage.new(),
      events_rev: [],
      events_dropped: 0,
      verdict: :empty,
      op_seq: 0,
      pending_provider_calls: %{},
      transcript_revision: resume_revision(opts),
      persistence_errors: [],
      request_model_tools: nil,
      event_sink: Keyword.get(opts, :event_sink, fn _event -> :ok end),
      cancel_ref: Keyword.get(opts, :cancel_ref),
      session: Keyword.get(opts, :session),
      session_dir: Keyword.get(opts, :session_dir),
      compaction_count: 0,
      retry_policy: Keyword.get(opts, :retry_policy),
      tool_presenter: Keyword.get(opts, :tool_presenter),
      agent_identity: agent_identity,
      max_agent_depth:
        min(
          settings.child_limits.max_depth,
          Keyword.get(opts, :parent_max_agent_depth, settings.child_limits.max_depth)
        ),
      workspaces:
        Keyword.get(opts, :parent_workspaces) ||
          settings.child_limits.workspaces,
      tool_specs: Keyword.get(opts, :tools, []),
      prompt_config: Keyword.take(opts, [:prompt, :project_instructions])
    }

    if Alto.AgentIdentity.valid?(agent_identity),
      do: {:ok, Map.merge(initial, settings)},
      else: {:error, {:invalid_option, :agent_identity, agent_identity}}
  end

  # A provider is model capability state: generic rule runs are constructed
  # without one and fail closed only if a model effect is requested.
  def normalize_provider(nil), do: {:ok, nil}

  def normalize_provider(spec), do: Alto.Capabilities.resolve(spec, Alto.Provider)

  defp resolve_child_policy(nil, _budget, _timeout, _cancel_ref),
    do: Alto.Subagents.Policy.resolve(nil)

  defp resolve_child_policy(policy, budget, timeout, cancel_ref) do
    case Alto.Runner.Execution.Call.run(
           fn -> Alto.Subagents.Policy.resolve(policy) end,
           Budget.timeout(budget, timeout),
           cancel_ref
         ) do
      {:ok, result} -> result
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      {:error, reason} -> {:error, {:subagent_policy_failed, reason}}
    end
  end

  defp resolve_budget(opts) do
    case Keyword.get(opts, :budget) do
      nil -> Budget.new(opts)
      %Budget{} = budget -> {:ok, budget}
      other -> {:error, {:invalid_budget, other}}
    end
  end

  defp resume_revision(opts) do
    case {Keyword.fetch(opts, :parent_transcript_revision), Keyword.get(opts, :checkpoint),
          Keyword.get(opts, :resume)} do
      {{:ok, revision}, _, _} ->
        revision

      {_, {%{"transcript_revision" => revision}, _}, _}
      when is_integer(revision) and revision >= 0 ->
        revision

      {_, _, %{revision: revision}} when is_integer(revision) and revision >= 1 ->
        revision

      _ ->
        :any
    end
  end

  defp normalize_approval({module, opts}) when is_atom(module) and is_list(opts),
    do: {:ok, {module, opts}}

  defp normalize_approval(module) when is_atom(module), do: {:ok, {module, []}}
  defp normalize_approval(other), do: {:error, {:invalid_approval, other}}

  # Continuations restore their exact transcript after capabilities are opened.
  # Conversation resumes reuse history; only fresh runs build a system prompt.
  defp init_transcript(task, opts, cwd, tools, provider, max_transcript_bytes) do
    cond do
      opts[:checkpoint] || opts[:continuation] ->
        {:ok, [], 0}

      Keyword.has_key?(opts, :resume) ->
        with {:ok, history} <- resume_history(Keyword.fetch!(opts, :resume)) do
          prepend_task(task, history, max_transcript_bytes)
        end

      true ->
        fresh_transcript(task, opts, cwd, tools, provider, max_transcript_bytes)
    end
  end

  # Generic rule runs have no model transcript or project instructions.
  defp fresh_transcript(_task, opts, _cwd, _tools, nil, _max_transcript_bytes) do
    if Keyword.get(opts, :prompt) in [nil, ""],
      do: {:ok, [], 0},
      else: {:error, :prompt_options_require_provider}
  end

  defp fresh_transcript(task, opts, cwd, tools, _provider, max_transcript_bytes) do
    with {:ok, project_instructions} <- resolve_project_instructions(opts, cwd),
         {:ok, prompt} <- resolve_system_prompt(opts, cwd, tools, project_instructions) do
      history = if prompt, do: [%{"role" => "system", "content" => prompt}], else: []
      prepend_task(task, history, max_transcript_bytes)
    end
  end

  defp prepend_task(task, history, max_transcript_bytes) do
    messages_rev = [%{"role" => "user", "content" => task_text(task)} | Enum.reverse(history)]
    bytes = Transcript.bytes(messages_rev)

    if bytes <= max_transcript_bytes,
      do: {:ok, messages_rev, bytes},
      else: {:error, {:transcript_limit, max_transcript_bytes}}
  end

  defp resume_history(%{messages: messages, transcript_bytes: bytes})
       when is_list(messages) and is_integer(bytes) and bytes >= 0,
       do: Transcript.close_interrupted(messages)

  defp resume_history(other), do: {:error, {:invalid_resume, other}}

  # `:auto` resolves bounded workspace text for model-backed runs.
  defp resolve_project_instructions(opts, cwd) do
    case Keyword.get(opts, :project_instructions) do
      nil ->
        {:ok, nil}

      :auto ->
        Alto.Project.load(cwd)

      options when is_list(options) ->
        if Keyword.keyword?(options),
          do: Alto.Project.load(cwd, options),
          else: {:error, {:invalid_project_instructions, options}}

      other ->
        {:error, {:invalid_project_instructions, other}}
    end
  end

  defp resolve_system_prompt(opts, cwd, tools, project_instructions) do
    Alto.Prompt.build(Keyword.get(opts, :prompt), %{
      cwd: cwd,
      tools: tools,
      project_instructions: project_instructions
    })
  end

  defp validate_spec(%Alto.Loop.Spec{}), do: :ok
  defp validate_spec(other), do: {:error, {:invalid_loop, other}}

  defp validate_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, {:invalid_cwd, path}}
  end

  @compaction_schema [
    strategy: [type: :any, default: {Alto.Context.Reducers.Summary, []}],
    max_compactions: [type: :pos_integer, default: 1],
    keep_recent_messages: [type: :pos_integer, default: 10],
    keep_initial_messages: [type: :non_neg_integer, default: 0],
    max_input_bytes: [type: :pos_integer, default: 100_000],
    request_mode: [type: {:in, [:transcript, :isolated]}, default: :transcript],
    max_summary_bytes: [type: :pos_integer, default: 8_000],
    max_handoff_bytes: [type: :pos_integer, default: 24_000],
    artifact_dir: [type: :any, default: nil]
  ]

  defp normalize_compaction(false), do: {:ok, false}
  defp normalize_compaction(true), do: normalize_compaction([])

  defp normalize_compaction(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, normalized} <- NimbleOptions.validate(opts, @compaction_schema),
         {:ok, strategy} <- Alto.Context.Reducer.resolve(normalized[:strategy]),
         :ok <- validate_artifact_dir(normalized[:artifact_dir]) do
      {:ok, Keyword.put(normalized, :strategy, strategy)}
    else
      false -> {:error, {:invalid_compaction, opts}}
      {:error, reason} -> {:error, {:invalid_compaction, reason}}
    end
  end

  defp normalize_compaction(other), do: {:error, {:invalid_compaction, other}}

  defp validate_artifact_dir(nil), do: :ok
  defp validate_artifact_dir(path) when is_binary(path) and path != "", do: :ok
  defp validate_artifact_dir(path), do: {:error, {:invalid_artifact_dir, path}}

  defp validate_session_dir(nil), do: :ok
  defp validate_session_dir(dir) when is_binary(dir), do: :ok
  defp validate_session_dir(other), do: {:error, {:invalid_session_dir, other}}

  defp persist_start(run, opts, task) do
    if run.session do
      {provider_module, model} = provider_identity(run.provider)

      record =
        Session.started_record(%{
          run_id: run.tool_context.session_id,
          parent_run_id: Keyword.get(opts, :parent_run_id),
          parent_session_id: Keyword.get(opts, :parent_session_id),
          agent_identity: run.agent_identity,
          subagent: run.agent_depth > 0,
          session_owner: run.agent_depth == 0 or run.resume_snapshot,
          task: task,
          provider: provider_module,
          model: model,
          cwd: run.tool_context.cwd
        })

      case Session.append(run.session, record, session_dir_opt(run)) do
        :ok ->
          {:ok, run}

        {:error, reason} ->
          Logger.warning("alto: session not opened: #{inspect(reason, limit: 5)}")
          {:ok, add_persistence_error(run, reason)}
      end
    else
      {:ok, run}
    end
  end

  defp add_persistence_error(run, reason),
    do: Map.update(run, :persistence_errors, [reason], &[reason | &1])

  defp generate_run_id,
    do: "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp session_dir_opt(run), do: [session_dir: run.session_dir]
  defp task_text(task) when is_binary(task), do: task
  defp task_text(task), do: inspect(task)
  defp provider_identity(nil), do: {nil, nil}

  defp provider_identity({module, opts}) when is_atom(module) and is_list(opts) do
    {Atom.to_string(module), Keyword.get(opts, :model)}
  end
end
