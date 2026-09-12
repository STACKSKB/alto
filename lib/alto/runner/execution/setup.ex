defmodule Alto.Runner.Execution.Setup do
  @moduledoc "Build validated execution capabilities from trusted run options."
  alias Alto.{Session, Usage}
  alias Alto.Tool.Context
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget
  alias Alto.Subagents.Bounded, as: BoundedSubagents
  require Logger
  @default_max_steps 32
  @default_tool_timeout 125_000
  @default_provider_timeout 125_000
  @default_approval_timeout 300_000
  @default_max_approval_details_bytes 64_000
  @default_max_tool_result_bytes 64_000
  @default_max_transcript_bytes 8_000_000
  @default_max_events 1_000
  @default_provider_retries 0
  @default_compaction_keep_messages 10
  @default_compaction_max_summary_bytes 8_000
  @default_compaction_max_handoff_bytes 24_000
  def open(task, opts) do
    spec = Keyword.get(opts, :loop, Alto.default_loop())

    provider =
      normalize_provider(Keyword.get(opts, :provider), Keyword.get(opts, :provider_options, []))

    tools = Keyword.get(opts, :tools, [])
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    provider_timeout = Keyword.get(opts, :provider_timeout, @default_provider_timeout)
    tool_timeout = Keyword.get(opts, :tool_timeout, @default_tool_timeout)
    approval_timeout = Keyword.get(opts, :approval_timeout, @default_approval_timeout)
    approval = normalize_approval(Keyword.get(opts, :approval, Alto.Approvals.DenyAll))

    max_approval_details_bytes =
      Keyword.get(
        opts,
        :max_approval_details_bytes,
        @default_max_approval_details_bytes
      )

    max_tool_result_bytes =
      Keyword.get(opts, :max_tool_result_bytes, @default_max_tool_result_bytes)

    max_transcript_bytes =
      Keyword.get(opts, :max_transcript_bytes, @default_max_transcript_bytes)

    max_events = Keyword.get(opts, :max_events, @default_max_events)

    with :ok <- validate_spec(spec),
         {:ok, budget} <- resolve_budget(opts),
         {:ok, provider} <- provider,
         {:ok, approval} <- approval,
         :ok <- validate_directory(cwd),
         :ok <- positive(:max_steps, max_steps),
         :ok <- positive(:provider_timeout, provider_timeout),
         :ok <- positive(:tool_timeout, tool_timeout),
         :ok <- positive(:approval_timeout, approval_timeout),
         :ok <- positive(:max_approval_details_bytes, max_approval_details_bytes),
         :ok <- positive(:max_tool_result_bytes, max_tool_result_bytes),
         :ok <- positive(:max_transcript_bytes, max_transcript_bytes),
         :ok <- positive(:max_events, max_events),
         {:ok, provider_retries} <-
           normalize_retries(Keyword.get(opts, :provider_retries, @default_provider_retries)),
         {:ok, compaction} <- normalize_compaction(Keyword.get(opts, :compaction, false)),
         {:ok, agent_depth} <- normalize_agent_depth(Keyword.get(opts, :agent_depth, 0)),
         {:ok, _agent_identity} <- normalize_agent_identity(Keyword.get(opts, :agent_identity)),
         {:ok, resume_snapshot} <-
           normalize_resume_snapshot(Keyword.get(opts, :resume_snapshot, true)),
         :ok <- validate_session_dir(Keyword.get(opts, :session_dir)),
         {:ok, tool_map, definitions} <- Alto.Tool.Registry.build(tools),
         {:ok, definitions, model_exposure} <-
           Alto.Tool.Registry.expose(
             definitions,
             tool_map,
             Keyword.get(opts, :model_tools),
             Keyword.get(opts, :parent_model_tools)
           ),
         {:ok, prompt_setup} <- prompt_setup(opts, cwd, tools, provider),
         {:ok, messages_rev, transcript_bytes} <-
           init_transcript(task, prompt_setup, max_transcript_bytes, opts),
         {:ok, run} <-
           build_run(
             %{
               spec: spec,
               provider: provider,
               provider_timeout: provider_timeout,
               tools: tool_map,
               tool_definitions: definitions,
               tool_timeout: tool_timeout,
               approval: approval,
               approval_timeout: approval_timeout,
               max_approval_details_bytes: max_approval_details_bytes,
               max_tool_result_bytes: max_tool_result_bytes,
               max_transcript_bytes: max_transcript_bytes,
               max_events: max_events,
               max_steps: max_steps,
               messages_rev: messages_rev,
               transcript_bytes: transcript_bytes,
               model_tools: model_exposure,
               budget: budget
             },
             cwd,
             opts
           ) do
      init_run_extensions(run, opts, task,
        provider_retries: provider_retries,
        compaction: compaction,
        agent_depth: agent_depth,
        resume_snapshot: resume_snapshot
      )
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
      runner_options: Keyword.get(opts, :runner_options, []),
      checkpoint_version: Keyword.get(opts, :checkpoint_version),
      subagent_ticket: Keyword.get(opts, :subagent_ticket),
      child_profile: Keyword.get(opts, :child_profile),
      child_resume: Keyword.get(opts, :child_resume),
      parent_expires_at_ms: Keyword.get(opts, :parent_expires_at_ms),
      continuation_store: Keyword.get(opts, :continuation_store),
      continuation_key: Keyword.get(opts, :continuation_key),
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
      pending_provider_calls: rebuild_pending_provider_calls(Enum.reverse(settings.messages_rev)),
      transcript_revision: resume_revision(opts),
      persistence_errors: [],
      request_model_tools: nil,
      event_sink: Keyword.get(opts, :event_sink, fn _event -> :ok end),
      cancel_ref: Keyword.get(opts, :cancel_ref),
      session: nil,
      session_dir: nil,
      compaction: false,
      compacted?: false,
      provider_retries: @default_provider_retries,
      agent_depth: 0,
      agent_identity: agent_identity,
      max_agent_depth: 0,
      workspaces:
        Keyword.get(opts, :parent_workspaces) ||
          Alto.Runner.Execution.Children.configured_workspaces(settings.spec.subagents),
      subagent_journal:
        Keyword.get(opts, :parent_subagent_journal) ||
          Alto.Runner.Execution.Children.configured_subagent_journal(settings.spec.subagents),
      resume_snapshot: true,
      tool_specs: [],
      prompt_config: []
    }

    with {:ok, _} <- normalize_agent_identity(agent_identity),
         do: {:ok, Map.merge(initial, settings)}
  end

  # A provider is model capability state: generic rule runs are constructed
  # without one and fail closed only if a model effect is requested.
  def normalize_provider(nil, _opts), do: {:ok, nil}

  def normalize_provider({module, opts}, _fallback) when is_atom(module) and is_list(opts),
    do: provider_contract(module, opts)

  def normalize_provider(module, opts) when is_atom(module) and is_list(opts),
    do: provider_contract(module, opts)

  def normalize_provider(other, _opts), do: {:error, {:invalid_provider, other}}

  defp provider_contract(module, opts) do
    if module != nil and Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
         function_exported?(module, :stream, 3) and function_exported?(module, :describe, 1),
       do: {:ok, {module, opts}},
       else: {:error, {:invalid_provider, module}}
  end

  defp resolve_budget(opts) do
    case Keyword.get(opts, :budget) do
      nil -> Budget.new(opts)
      %Budget{} = budget -> {:ok, budget}
      other -> {:error, {:invalid_budget, other}}
    end
  end

  defp resume_revision(opts) do
    if Keyword.has_key?(opts, :parent_transcript_revision) do
      Keyword.fetch!(opts, :parent_transcript_revision)
    else
      ordinary_resume_revision(opts)
    end
  end

  defp ordinary_resume_revision(opts) do
    case Keyword.get(opts, :checkpoint) do
      {%{"transcript_revision" => revision}, _decision}
      when is_integer(revision) and revision >= 0 ->
        revision

      _ ->
        transcript_resume_revision(opts)
    end
  end

  defp transcript_resume_revision(opts) do
    case Keyword.get(opts, :resume) do
      %{revision: revision} when is_integer(revision) and revision >= 1 -> revision
      _other -> :any
    end
  end

  defp normalize_approval({module, opts}) when is_atom(module) and is_list(opts),
    do: {:ok, {module, opts}}

  defp normalize_approval(module) when is_atom(module), do: {:ok, {module, []}}
  defp normalize_approval(other), do: {:error, {:invalid_approval, other}}

  # Resume reuses stored history verbatim: prompt and project-instruction
  # options are evaluated for fresh runs only and ignored on resume, where
  # the history already carries its own system message.
  defp prompt_setup(opts, cwd, tools, provider) do
    if Keyword.has_key?(opts, :resume) do
      {:ok, :resumed}
    else
      with {:ok, project_instructions} <- resolve_project_instructions(opts, cwd, provider),
           {:ok, prompt} <- resolve_prompt_state(opts, cwd, tools, provider, project_instructions) do
        {:ok, {:fresh, prompt}}
      end
    end
  end

  defp init_transcript(task, :resumed, max_transcript_bytes, opts) do
    with {:ok, history, history_bytes} <- resume_history(Keyword.fetch!(opts, :resume)) do
      user_message = %{"role" => "user", "content" => task_text(task)}
      messages_rev = [user_message | Enum.reverse(history)]
      transcript_bytes = history_bytes + byte_size(JSON.encode!(user_message))

      if transcript_bytes > max_transcript_bytes do
        {:error, {:transcript_limit, max_transcript_bytes}}
      else
        {:ok, messages_rev, transcript_bytes}
      end
    end
  end

  defp init_transcript(task, {:fresh, prompt}, max_transcript_bytes, _opts) do
    init_transcript(task, prompt, max_transcript_bytes)
  end

  defp resume_history(%{messages: messages, transcript_bytes: bytes})
       when is_list(messages) and is_integer(bytes) and bytes >= 0 do
    with :ok <- Transcript.validate(messages, allow_pending: true),
         {:ok, messages} <- Transcript.close_interrupted(messages) do
      {:ok, messages, Transcript.bytes(messages)}
    end
  end

  defp resume_history(other), do: {:error, {:invalid_resume, other}}

  # Prompt and transcript state are model capability state. Generic
  # provider-less runs carry no prompt configuration; requesting one is a
  # configuration error rather than silently ignored input.
  defp resolve_prompt_state(opts, _cwd, _tools, nil, _project_instructions) do
    system_prompt = Keyword.get(opts, :system_prompt, :absent)
    prompt = Keyword.get(opts, :prompt, :absent)

    if (is_binary(system_prompt) and system_prompt != "") or
         (prompt != :absent and not is_nil(prompt)) do
      {:error, :prompt_options_require_provider}
    else
      {:ok, :generic}
    end
  end

  defp resolve_prompt_state(opts, cwd, tools, _provider, project_instructions),
    do: resolve_system_prompt(opts, cwd, tools, project_instructions)

  defp init_transcript(_task, :generic, _max_transcript_bytes), do: {:ok, [], 0}

  defp init_transcript(task, system_prompt, max_transcript_bytes) do
    user_message = %{"role" => "user", "content" => task_text(task)}

    messages_rev =
      case system_prompt do
        prompt when is_binary(prompt) and prompt != "" ->
          [user_message, %{"role" => "system", "content" => prompt}]

        _other ->
          [user_message]
      end

    transcript_bytes =
      messages_rev
      |> Enum.reduce(0, fn message, total -> total + byte_size(JSON.encode!(message)) end)

    if transcript_bytes > max_transcript_bytes do
      {:error, {:transcript_limit, max_transcript_bytes}}
    else
      {:ok, messages_rev, transcript_bytes}
    end
  end

  # Project instructions are model capability state: `:auto` resolves bounded
  # workspace text at construction and is inert in generic provider-less runs.
  defp resolve_project_instructions(_opts, _cwd, nil), do: {:ok, nil}

  defp resolve_project_instructions(opts, cwd, _provider) do
    case Keyword.get(opts, :project_instructions) do
      nil -> {:ok, nil}
      :auto -> Alto.Project.load(cwd)
      other -> {:error, {:invalid_project_instructions, other}}
    end
  end

  defp resolve_system_prompt(opts, cwd, tools, project_instructions) do
    case {Keyword.fetch(opts, :system_prompt), Keyword.fetch(opts, :prompt)} do
      {{:ok, _system_prompt}, {:ok, _builder}} ->
        {:error, :conflicting_prompt_options}

      {{:ok, prompt}, :error} when is_binary(prompt) and prompt != "" ->
        {:ok, prompt}

      {{:ok, prompt}, :error} when prompt in [nil, ""] ->
        {:ok, nil}

      {{:ok, invalid}, :error} ->
        {:error, {:invalid_system_prompt, invalid}}

      {:error, {:ok, builder}} ->
        Alto.Prompt.build(builder, %{
          cwd: cwd,
          tools: tools,
          project_instructions: project_instructions
        })

      {:error, :error} ->
        {:ok, nil}
    end
  end

  defp validate_spec(%Alto.Loop.Spec{}), do: :ok
  defp validate_spec(other), do: {:error, {:invalid_loop, other}}

  defp validate_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, {:invalid_cwd, path}}
  end

  defp positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp positive(name, value), do: {:error, {:invalid_option, name, value}}

  defp non_negative(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp non_negative(name, value), do: {:error, {:invalid_option, name, value}}

  defp normalize_retries(value) do
    case non_negative(:provider_retries, value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_agent_depth(value) do
    case non_negative(:agent_depth, value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_agent_identity(nil), do: {:ok, nil}

  defp normalize_agent_identity(%{root_run_id: root_run_id, path: path} = identity)
       when is_binary(root_run_id) and byte_size(root_run_id) in 1..256 and is_list(path) do
    if map_size(identity) == 2 and length(path) <= 64 and
         String.valid?(root_run_id) and
         Enum.all?(path, &(is_binary(&1) and byte_size(&1) in 1..256 and String.valid?(&1))) do
      {:ok, identity}
    else
      {:error, {:invalid_option, :agent_identity, identity}}
    end
  end

  defp normalize_agent_identity(other),
    do: {:error, {:invalid_option, :agent_identity, other}}

  defp normalize_resume_snapshot(value) when value in [true, false], do: {:ok, value}
  defp normalize_resume_snapshot(other), do: {:error, {:invalid_option, :resume_snapshot, other}}

  @compaction_defaults [
    strategy: :summary,
    keep_recent_messages: @default_compaction_keep_messages,
    max_summary_bytes: @default_compaction_max_summary_bytes,
    max_handoff_bytes: @default_compaction_max_handoff_bytes,
    artifact_dir: nil
  ]

  defp normalize_compaction(false), do: {:ok, false}
  defp normalize_compaction(true), do: {:ok, @compaction_defaults}

  defp normalize_compaction(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, normalized} <- Keyword.validate(opts, @compaction_defaults),
           :ok <- validate_compaction_strategy(Keyword.fetch!(normalized, :strategy)),
           :ok <-
             positive(:keep_recent_messages, Keyword.fetch!(normalized, :keep_recent_messages)),
           :ok <- positive(:max_summary_bytes, Keyword.fetch!(normalized, :max_summary_bytes)),
           :ok <- positive(:max_handoff_bytes, Keyword.fetch!(normalized, :max_handoff_bytes)),
           :ok <- validate_artifact_dir(Keyword.fetch!(normalized, :artifact_dir)) do
        {:ok, normalized}
      else
        {:error, reason} -> {:error, {:invalid_compaction, reason}}
      end
    else
      {:error, {:invalid_compaction, opts}}
    end
  end

  defp normalize_compaction(other), do: {:error, {:invalid_compaction, other}}

  defp validate_compaction_strategy(strategy) when strategy in [:summary, :handoff], do: :ok

  defp validate_compaction_strategy({module, opts}) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request, 3) and
         function_exported?(module, :decode, 3) and Keyword.keyword?(opts),
       do: :ok,
       else: {:error, {:invalid_strategy, module}}
  end

  defp validate_compaction_strategy(strategy), do: {:error, {:invalid_strategy, strategy}}

  defp validate_artifact_dir(nil), do: :ok
  defp validate_artifact_dir(path) when is_binary(path) and path != "", do: :ok
  defp validate_artifact_dir(path), do: {:error, {:invalid_artifact_dir, path}}

  defp validate_session_dir(nil), do: :ok
  defp validate_session_dir(dir) when is_binary(dir), do: :ok
  defp validate_session_dir(other), do: {:error, {:invalid_session_dir, other}}

  defp init_run_extensions(run, opts, task, extensions) do
    run = %{
      run
      | session: Keyword.get(opts, :session),
        session_dir: Keyword.get(opts, :session_dir),
        compaction: Keyword.fetch!(extensions, :compaction),
        compacted?: false,
        provider_retries: Keyword.fetch!(extensions, :provider_retries),
        agent_depth: Keyword.fetch!(extensions, :agent_depth),
        resume_snapshot: Keyword.fetch!(extensions, :resume_snapshot),
        max_agent_depth:
          min(
            max_agent_depth(run.spec),
            Keyword.get(opts, :parent_max_agent_depth, max_agent_depth(run.spec))
          ),
        tool_specs: Keyword.get(opts, :tools, []),
        prompt_config: Keyword.take(opts, [:prompt, :system_prompt, :project_instructions])
    }

    if run.session do
      {provider_module, model} = provider_identity(run.provider)

      record =
        Session.started_record(%{
          run_id: run.tool_context.session_id,
          parent_run_id: Keyword.get(opts, :parent_run_id),
          parent_session_id: Keyword.get(opts, :parent_session_id),
          agent_identity: run.agent_identity,
          subagent: Keyword.fetch!(extensions, :agent_depth) > 0,
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

  defp max_agent_depth(%{subagents: %BoundedSubagents{max_depth: max}})
       when is_integer(max) and max >= 0,
       do: max

  defp max_agent_depth(_spec), do: 0

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

  defp rebuild_pending_provider_calls(messages) do
    Enum.reduce(messages, %{}, fn
      %{"role" => "assistant", "tool_calls" => calls}, pending when is_list(calls) ->
        Enum.reduce(calls, pending, fn call, inner ->
          key = {call["id"], get_in(call, ["function", "name"])}
          Map.update(inner, key, 1, &(&1 + 1))
        end)

      %{"role" => "tool", "tool_call_id" => id}, pending ->
        case Enum.find(pending, fn {{call_id, _name}, count} -> call_id == id and count > 0 end) do
          {key, 1} -> Map.delete(pending, key)
          {key, count} -> Map.put(pending, key, count - 1)
          nil -> pending
        end

      _message, pending ->
        pending
    end)
  end
end
