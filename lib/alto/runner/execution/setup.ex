defmodule Alto.Runner.Execution.Setup do
  @moduledoc "Build execution capabilities from trusted run options."
  alias Alto.{Session, Usage}
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget

  @limits_options Alto.Config.execution_limits()
  @limits_schema NimbleOptions.new!(@limits_options)

  @option_fields ~w(provider_profiles credentials_path input messaging async_agents
                    agent_scheduler execution_owner checkpoint_version subagent_ticket child_profile
                    child_resume parent_expires_at_ms continuation_store cancel_ref session
                    session_dir retry_policy tool_presenter)a

  def open(task, opts) do
    %{} = spec = Keyword.get(opts, :loop, Alto.default_loop())

    provider = normalize_provider(Keyword.get(opts, :provider))

    tools = Keyword.get(opts, :tools, [])
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    approval = Keyword.get(opts, :approval, {:deny, :policy_denied})

    with {:ok, limits} <- limits(opts),
         {:ok, budget} <- resolve_budget(opts[:budget], opts),
         {:ok, child_limits} <-
           resolve_child_policy(
             spec.subagents,
             budget,
             limits.tool_timeout,
             Keyword.get(opts, :cancel_ref)
           ),
         :ok <- validate_directory(cwd),
         {:ok, compaction} <- normalize_compaction(Keyword.get(opts, :compaction, false)),
         {:ok, tool_map} <- Alto.Tool.Registry.build(tools, child_limits),
         {:ok, definitions, model_exposure} <-
           Alto.Tool.Registry.expose(
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

    options = Map.new(@option_fields, &{&1, Keyword.get(opts, &1)})

    initial = %{
      loop_state: nil,
      runner: Keyword.get(opts, :runner, Alto.Runner.default()),
      resolved_operations: [],
      history_digest: nil,
      resume_context_observation:
        Map.get(Keyword.get(opts, :resume) || %{}, "context_observation"),
      checkpoint_resume:
        not is_nil(Keyword.get(opts, :checkpoint)) or not is_nil(Keyword.get(opts, :continuation)),
      session_id: session_id,
      cwd: cwd,
      metadata: Keyword.get(opts, :tool_context_metadata, %{}),
      input_reader: Keyword.get(opts, :input_reader),
      messaging_tools:
        Keyword.get(opts, :messaging_tools, Alto.Messaging.allowed_tools(settings)),
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
      compaction_count: 0,
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
      do: {:ok, options |> Map.merge(initial) |> Map.merge(settings)},
      else: {:error, {:invalid_option, :agent_identity, agent_identity}}
  end

  def normalize_provider(nil), do: nil

  def normalize_provider(spec), do: Alto.Capabilities.normalize(spec)

  defp resolve_child_policy(factory, budget, timeout, cancel_ref) when is_function(factory, 0) do
    case Alto.Runner.Execution.Call.run(factory, Budget.timeout(budget, timeout), cancel_ref) do
      {:error, _} = error -> error
      policy -> {:ok, policy}
    end
  end

  defp resolve_child_policy(policy, _budget, _timeout, _cancel_ref),
    do: {:ok, policy || Alto.Subagents.bounded(max_children: 1)}

  defp resolve_budget(nil, opts), do: Budget.new(opts)
  defp resolve_budget(%Budget{} = budget, _opts), do: {:ok, budget}

  defp resume_revision(opts) do
    case {Keyword.fetch(opts, :parent_transcript_revision), Keyword.get(opts, :checkpoint),
          Keyword.get(opts, :resume)} do
      {{:ok, revision}, _, _} ->
        revision

      {_, {%{"transcript_revision" => revision}, _}, _}
      when is_integer(revision) and revision >= 0 ->
        revision

      {_, _, %{"revision" => revision}} when is_integer(revision) and revision >= 1 ->
        revision

      _ ->
        :any
    end
  end

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
    instructions =
      case opts[:project_instructions] do
        nil -> {:ok, nil}
        :auto -> Alto.Project.load(cwd)
        options when is_list(options) -> Alto.Project.load(cwd, options)
      end

    with {:ok, instructions} <- instructions,
         prompt <-
           Alto.Prompt.build(opts[:prompt], %{
             cwd: cwd,
             tools: tools,
             project_instructions: instructions
           }) do
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

  defp resume_history(%{"messages" => messages, "transcript_bytes" => bytes})
       when is_list(messages) and is_integer(bytes) and bytes >= 0,
       do: Transcript.close_interrupted(messages)

  defp resume_history(other), do: {:error, {:invalid_resume, other}}

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
    artifact_dir: [type: {:or, [:string, nil]}, default: nil]
  ]

  defp normalize_compaction(false), do: {:ok, false}
  defp normalize_compaction(true), do: normalize_compaction([])

  defp normalize_compaction(opts) do
    normalized = NimbleOptions.validate!(opts, @compaction_schema)

    {:ok, Keyword.update!(normalized, :strategy, &Alto.Capabilities.normalize/1)}
  end

  defp persist_start(run, opts, task) do
    errors =
      Alto.Runner.Execution.Session.append(
        run,
        "not opened",
        fn ->
          {provider_module, model} = provider_identity(run.provider)

          Session.started_record(%{
            run_id: run.session_id,
            parent_run_id: Keyword.get(opts, :parent_run_id),
            parent_session_id: Keyword.get(opts, :parent_session_id),
            agent_identity: run.agent_identity,
            agent_id: run.messaging && run.messaging.id,
            subagent: run.agent_depth > 0,
            session_owner: run.agent_depth == 0 or run.resume_snapshot,
            task: task,
            provider: provider_module,
            model: model,
            cwd: run.cwd
          })
        end
      )

    {:ok, %{run | persistence_errors: errors ++ run.persistence_errors}}
  end

  defp generate_run_id,
    do: "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp task_text(task) when is_binary(task), do: task
  defp task_text(task), do: inspect(task)
  defp provider_identity(nil), do: {nil, nil}

  defp provider_identity({module, opts}) when is_atom(module) and is_list(opts) do
    {Atom.to_string(module), Keyword.get(opts, :model)}
  end
end
