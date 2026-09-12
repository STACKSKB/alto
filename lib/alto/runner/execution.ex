defmodule Alto.Runner.Execution do
  @moduledoc """
  Shared effect execution and run assembly for Alto hosts.

  `run/3` opens configured capabilities and persistence, then hands an opaque
  execution context and a frame to the supplied scheduler. `step/2` executes
  at most one effect. Schedulers choose when to advance; pure loop transitions
  decide which effects are requested. Tool, model, transcript, child and
  persistence components are independently usable below this assembly layer.
  """
  defmodule Frame do
    @moduledoc "Pending ordered effects and the disposition after they drain."
    defstruct effects: [], terminal: :continue
    @type t :: %__MODULE__{effects: [Alto.Effect.t()], terminal: term()}
  end

  @opaque context :: map()

  @doc "Check cancellation and the shared deadline without executing an effect."
  def check(context) do
    case Alto.Runner.Execution.Call.cancellation(context.cancel_ref) do
      :continue -> Alto.Runner.Budget.check(context.budget)
      cancelled -> cancelled
    end
  end

  @doc "Build a terminal outcome when a scheduler stops before its next effect."
  def abort(context, {:cancelled, reason}), do: cancelled(reason, context)
  def abort(context, reason), do: {:error, reason, result(context, nil, :error)}

  alias Alto.Effect
  alias Alto.Effect.Outcome
  alias Alto.Event
  alias Alto.Runner.Result
  alias Alto.Runtime
  alias Alto.Session
  alias Alto.Transition
  alias Alto.Usage
  alias Alto.Context.Window
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget

  require Logger

  @type provider_spec :: module() | {module(), keyword()}
  @type approval_spec :: module() | {module(), keyword()}
  @type run_result :: {:ok, Result.t()} | {:error, term(), Result.t()}

  @spec run(term(), keyword(), (Frame.t(), context() -> run_result())) :: run_result()
  def run(task, opts, scheduler) do
    opts = Keyword.put(opts, :execution_scheduler, scheduler)

    outcome =
      case Keyword.get(opts, :workspace_resume) do
        {manager, id, revision} ->
          Alto.Runner.Execution.Workspace.resume(
            task,
            opts,
            manager,
            id,
            revision,
            &run_without_workspace/2
          )

        nil ->
          case Keyword.pop(opts, :workspace_assignment) do
            {nil, opts} ->
              run_without_workspace(task, opts)

            {{manager, snapshot, identity}, opts} ->
              run_in_workspace(task, opts, manager, snapshot, identity)
          end
      end

    retain_child_outcome(Keyword.get(opts, :subagent_ticket), outcome)
  end

  defp run_without_workspace(task, opts) do
    case Alto.Runner.Execution.Parent.options(opts) do
      {:ok, opts} -> run_with_options(task, opts)
      {:error, reason} -> {:error, reason, empty_result(nil)}
    end
  end

  defp run_with_options(task, opts) do
    opts = Keyword.put_new_lazy(opts, :session_id, &generate_run_id/0)

    opts =
      case Keyword.get(opts, :checkpoint) do
        {%{"session_id" => session}, _decision} -> Keyword.put(opts, :session, session)
        _ -> opts
      end

    case normalize_session_opt(Keyword.get(opts, :session)) do
      {:ok, session} ->
        opts = Keyword.put(opts, :session, session)

        case new_run(task, opts) do
          {:ok, run} ->
            outcome =
              case {Keyword.get(opts, :continuation), Keyword.get(opts, :checkpoint)} do
                {identity, nil} when not is_nil(identity) ->
                  Alto.Runner.Execution.Parent.resume(
                    run,
                    identity,
                    opts,
                    &complete_retained_batch/5
                  )
                  |> parent_outcome()

                {nil, nil} ->
                  case call_policy(fn -> Runtime.init(run.spec, task) end, run) do
                    {:ok, transition} -> drive(transition, run, [])
                    {:cancelled, reason} -> cancelled(reason, run)
                    {:error, reason} -> {:error, reason, result(run, nil, :error)}
                  end

                {nil, {packet, decision}} ->
                  resume_checkpoint(run, packet, decision, opts)

                _ ->
                  {:error, :invalid_checkpoint, result(run, nil, :error)}
              end

            outcome =
              case outcome do
                {:continue, frame, context} ->
                  Keyword.fetch!(opts, :execution_scheduler).(frame, context)

                {:done, result} ->
                  result

                result ->
                  result
              end

            persist_session_outcome(run, outcome)

          {:error, reason} ->
            {:error, reason, empty_result(session)}
        end

      {:error, reason} ->
        {:error, reason, empty_result(nil)}
    end
  end

  defp drive(%Transition{} = transition, run, remaining_effects) do
    run = %{run | loop_state: transition.state}

    case transition.status do
      :continue -> execute(transition.effects ++ remaining_effects, run, :continue)
      :stop -> execute(transition.effects, run, {:stop, transition.result})
      :error -> execute(transition.effects, run, {:error, transition.error})
    end
  end

  defp execute(effects, run, terminal),
    do: {:continue, %Frame{effects: effects, terminal: terminal}, run}

  @doc "Execute at most one effect, returning the next frame or a final outcome."
  def step(%Frame{effects: effects, terminal: terminal}, run) do
    case {cancellation(run.cancel_ref), Budget.check(run.budget)} do
      {{:cancelled, reason}, _} -> {:done, cancelled(reason, run)}
      {_, {:error, reason}} -> {:done, {:error, reason, result(run, nil, :error)}}
      {:continue, :ok} -> do_execute(effects, run, terminal)
    end
  end

  defp do_execute([], run, {:stop, output}), do: {:done, {:ok, result(run, output, :success)}}

  defp do_execute([], run, {:error, reason}),
    do: {:done, {:error, reason, result(run, nil, :error)}}

  defp do_execute([], run, :continue),
    do: {:done, {:error, :loop_stalled, result(run, nil, :error)}}

  defp do_execute(
         [%Effect{kind: :spawn_agents, data: data} | rest],
         %{continuation_store: store} = run,
         terminal
       )
       when not is_nil(store) do
    case reserve_effect(run) do
      :ok ->
        Alto.Runner.Execution.Parent.start(data, rest, terminal, run, &complete_retained_batch/5)
        |> parent_outcome()

      error ->
        finish_effect(error, rest, run, terminal)
    end
  end

  defp do_execute([effect | rest], run, terminal) do
    interpreted = with :ok <- reserve_effect(run), do: interpret(effect, run)

    finish_effect(interpreted, rest, run, terminal)
  end

  defp reserve_effect(%{budget: %{account: nil}} = run), do: Budget.take(run.budget)

  defp reserve_effect(run) do
    case supervised_call(
           fn -> Budget.take(run.budget) end,
           Budget.remaining(run.budget),
           run.cancel_ref
         ) do
      {:ok, result} -> result
      {:cancelled, reason} -> {:cancelled, reason, run}
      {:error, :timeout} -> {:error, :run_timeout}
      {:error, reason} -> {:error, {:budget_account_unavailable, reason}}
    end
  end

  defp finish_effect(interpreted, rest, run, terminal) do
    case interpreted do
      {:suspend, pending, next_run} ->
        case checkpoint_call(
               fn ->
                 if next_run.agent_depth > 0,
                   do: Alto.Runner.Checkpoint.capture_child(next_run, pending, rest, terminal),
                   else: Alto.Runner.Checkpoint.capture(next_run, pending, rest, terminal)
               end,
               next_run
             ) do
          {:ok, packet} ->
            value = %{result(next_run, nil, :checkpoint) | checkpoint: packet}
            {:done, {:error, :approval_suspended, value}}

          {:error, reason} ->
            {:done, {:error, reason, result(next_run, nil, :error)}}
        end

      {:error, reason} ->
        {:done, {:error, reason, result(run, nil, :error)}}

      {:ok, next_run} ->
        execute(rest, next_run, terminal)

      {:event, event, next_run} ->
        next_run = record_event(next_run, event)

        case call_policy(
               fn ->
                 Runtime.dispatch(
                   next_run.spec,
                   event,
                   next_run.loop_state,
                   runtime_context(next_run)
                 )
               end,
               next_run
             ) do
          {:ok, transition} -> drive(transition, next_run, rest)
          {:cancelled, reason} -> {:done, cancelled(reason, next_run)}
          {:error, reason} -> {:done, {:error, reason, result(next_run, nil, :error)}}
        end

      {:error, {:cancelled, reason}, next_run} ->
        {:done, cancelled(reason, next_run)}

      {:error, reason, next_run} ->
        {:done, {:error, reason, result(next_run, nil, :error)}}

      {:cancelled, reason, next_run} ->
        {:done, cancelled(reason, next_run)}
    end
  end

  defp resume_checkpoint(run, packet, decision, opts) do
    with {:ok, restored, frame} <-
           checkpoint_call(
             fn ->
               if run.child_resume,
                 do: Alto.Runner.Checkpoint.restore_child(run, packet, decision, opts),
                 else: Alto.Runner.Checkpoint.restore(run, packet, decision, opts)
             end,
             run
           ),
         :ok <- Budget.check(restored.budget),
         {:ok, tool} <- fetch_tool(restored.tools, frame.pending.request.tool),
         :ok <- claim_child_checkpoint(restored, decision) do
      pending = frame.pending

      interpreted =
        if decision == :approve do
          run_tool(
            pending.request.call_id,
            pending.request.tool,
            pending.prepared,
            tool,
            restored,
            pending.request.operation_id,
            pending.origin
          )
        else
          tool_failure(
            pending.request.call_id,
            pending.request.tool,
            {:approval_denied, :user},
            restored,
            pending.request.operation_id,
            Outcome.pre_dispatch(:user),
            pending.origin
          )
        end

      finish_effect(interpreted, frame.remaining, restored, frame.terminal)
    else
      {:error, reason} ->
        value = result(run, nil, :error)

        value =
          if run.child_resume,
            do: %{value | checkpoint: %{"kind" => "child", "ungranted" => true}},
            else: value

        {:error, reason, value}
    end
  end

  defp claim_child_checkpoint(%{child_resume: nil}, _decision), do: :ok

  defp claim_child_checkpoint(run, decision) do
    case checkpoint_call(
           fn ->
             Alto.Subagents.Journal.claim_child(
               run.subagent_ticket,
               run.child_resume,
               decision
             )
           end,
           run
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp checkpoint_call(fun, run) do
    case supervised_call(fun, Budget.timeout(run.budget, 30_000), run.cancel_ref) do
      {:ok, value} -> value
      {:error, reason} -> {:error, {:checkpoint_process_failed, reason}}
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
    end
  end

  defp complete_retained_batch(results, journal, run, rest, terminal) do
    # Joining retained work cannot trigger an ungranted provider compaction.
    compaction = run.compaction
    interpreted = batch_completed(results, %{run | compaction: false}, journal)

    interpreted =
      case interpreted do
        {:event, event, next} -> {:event, event, %{next | compaction: compaction}}
        other -> other
      end

    finish_effect(interpreted, rest, run, terminal)
  end

  defp parent_outcome({:error, reason, run}),
    do: ungranted_parent({:error, reason, result(run, nil, :error)})

  defp parent_outcome({:cancelled, reason, run}), do: ungranted_parent(cancelled(reason, run))
  defp parent_outcome({:done, {:error, _, _} = outcome}), do: ungranted_parent(outcome)

  defp parent_outcome({:suspended, reason, identity, run}) do
    value = %{
      result(run, nil, :checkpoint)
      | checkpoint: %{"kind" => "parent", "continuation" => identity}
    }

    {:done, {:error, {:children_pending, reason}, value}}
  end

  defp parent_outcome(other), do: other

  defp ungranted_parent({:error, reason, value}) do
    {:done, {:error, reason, %{value | checkpoint: %{"kind" => "parent", "ungranted" => true}}}}
  end

  defp call_policy(fun, run) do
    case supervised_call(fun, Budget.timeout(run.budget, 30_000), run.cancel_ref) do
      {:ok, %Transition{} = transition} -> {:ok, transition}
      {:ok, other} -> {:error, {:invalid_transition, other}}
      {:error, reason} -> {:error, {:loop_process_failed, reason}}
      {:cancelled, reason} -> {:cancelled, reason}
    end
  end

  defp interpret(%Effect{kind: :emit, data: %{event: %Event{} = event}}, run) do
    {:event, event, run}
  end

  # Model requests are a model-specific effect: a generic provider-less run
  # fails closed if its loop policy requests one.
  defp interpret(%Effect{kind: :request_model}, %{provider: nil} = run),
    do: {:error, :provider_required, run}

  defp interpret(%Effect{kind: :request_model, data: request}, run) do
    with {:ok, run} <- request_context(request, run),
         :ok <- Transcript.validate(Enum.reverse(run.messages_rev)),
         {:ok, request} <- model_request(request, run),
         {:ok, request} <- check_context(request, run) do
      exposed = MapSet.new(Enum.map(request.tools, & &1["function"]["name"]))
      request_model(request, %{run | request_model_tools: exposed})
    else
      {:error, reason, updated} -> {:error, reason, updated}
      {:error, reason} -> {:error, reason, run}
    end
  end

  # Model-shaped invocation: the provider's arguments_json is the native
  # shape here and is decoded exactly once, on the way in. The provider call
  # id (`call.id`) is correlation only; the runtime mints a globally unique
  # operation id per invocation for approval and event correlation.
  defp interpret(%Effect{kind: :run_tool, data: call}, run) do
    name = Map.get(call, :name)
    call_id = Map.get(call, :id)
    {op_id, run} = next_operation(run)

    origin =
      case check_provider_correlation(run, call_id, name) do
        :ok -> :provider
        {:error, _reason} -> :native
      end

    case decode_arguments(Map.get(call, :arguments_json, "{}")) do
      {:ok, arguments} ->
        execute_tool(%{id: call_id, name: name, arguments: arguments}, run, origin, op_id)

      {:error, reason} ->
        tool_failure(
          call_id,
          name,
          reason,
          run,
          op_id,
          Outcome.pre_dispatch(reason),
          origin
        )
    end
  end

  # Native invocation from loops and hooks: arguments are already a map.
  defp interpret(%Effect{kind: :invoke_tool, data: call}, run) do
    name = Map.get(call, :name)
    arguments = Map.get(call, :arguments)
    {op_id, run} = next_operation(run)

    if is_map(arguments) do
      execute_tool(
        %{id: Map.get(call, :id), name: name, arguments: arguments},
        run,
        :native,
        op_id
      )
    else
      tool_failure(
        Map.get(call, :id),
        name,
        {:tool_arguments_not_map, arguments},
        run,
        op_id,
        Outcome.pre_dispatch(arguments),
        :native
      )
    end
  end

  defp interpret(%Effect{kind: :spawn_agent, data: data}, run) do
    case validate_spawn(data) do
      {:error, reason} ->
        {:error, {:invalid_spawn_agent, reason}, run}

      {:ok, spec} ->
        if run.agent_depth >= run.max_agent_depth do
          {:event, Event.durable(:subagent_failed, %{id: spec.id, error: :max_depth_exceeded}),
           run}
        else
          case validate_subagent_tools(spec.tools, run) do
            :ok -> run_subagent(spec, run)
            {:error, reason} -> {:event, subagent_failed(spec.id, reason), run}
          end
        end
    end
  end

  defp interpret(%Effect{kind: :spawn_agents, data: data}, run) do
    with {:ok, specs, concurrency} <- validate_batch(data, run),
         {:ok, status, outcomes, journal, run} <- run_children(specs, concurrency, run) do
      {results, run} =
        Enum.map_reduce(outcomes, run, fn {id, outcome}, acc ->
          {subagent_data(id, outcome), merge_child_result(acc, outcome)}
        end)

      case status do
        :ok -> batch_completed(results, run, journal)
        {:cancelled, reason} -> {:cancelled, reason, run}
        {:error, reason} -> {:error, reason, run}
      end
    else
      {:error, reason, run} -> {:error, reason, run}
      {:error, reason} -> {:error, {:invalid_spawn_agents, reason}, run}
    end
  end

  defp interpret(%Effect{} = effect, run), do: {:error, {:unknown_effect, effect.kind}, run}

  defp request_context(request, run) do
    case Map.fetch(request, :context_message) do
      :error ->
        {:ok, run}

      {:ok, content} when is_binary(content) ->
        if String.valid?(content),
          do: append_message(run, %{"role" => "user", "content" => content}),
          else: {:error, :invalid_context_message}

      _ ->
        {:error, :invalid_context_message}
    end
  end

  defp request_model(request, run) do
    if run.model_requests >= run.max_steps do
      {:error, {:model_step_limit, run.max_steps}, run}
    else
      live_sink = fn event -> notify(run.event_sink, event) end
      {provider, provider_opts} = run.provider
      step = run.model_requests + 1

      notify(run.event_sink, Event.live(:model_started, %{step: step}))

      outcome =
        stream_with_retries(provider, request, live_sink, provider_opts, run, step)

      run = %{run | model_requests: run.model_requests + 1}

      case outcome do
        {:ok, {:ok, completion}} -> complete_model(run, completion)
        {:ok, {:error, reason}} -> {:error, {:model_request_failed, reason}, run}
        {:error, reason} -> {:error, {:model_process_failed, reason}, run}
        {:cancelled, reason} -> {:cancelled, reason, run}
      end
    end
  end

  defp stringify_top_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp model_request(request, run) do
    options = Map.get(request, :options, %{})
    exposure = Map.get(request, :model_tools, MapSet.to_list(run.model_tools))

    cond do
      not is_map(options) ->
        {:error, :invalid_model_options}

      not Enum.all?(Map.keys(options), &(is_atom(&1) or is_binary(&1))) ->
        {:error, :invalid_model_options}

      Enum.any?(Map.keys(options), &(to_string(&1) in ["messages", "tools", "model", "stream"])) ->
        {:error, :reserved_model_option}

      not is_list(exposure) or not Enum.all?(exposure, &MapSet.member?(run.model_tools, &1)) ->
        {:error, :invalid_request_model_tools}

      true ->
        tools = Enum.filter(run.tool_definitions, &(&1["function"]["name"] in exposure))

        {:ok,
         %{
           messages: Enum.reverse(run.messages_rev),
           tools: tools,
           options: stringify_top_keys(options),
           loop: request
         }}
    end
  end

  defp model_capabilities(run) do
    struct!(
      Alto.Runner.Execution.Model.Capabilities,
      Map.take(run, [:budget, :cancel_ref, :provider_timeout, :provider_retries, :event_sink])
    )
  end

  defp check_context(request, %{spec: %{context: %Window{} = policy}} = run) do
    {provider, opts} = run.provider

    Alto.Runner.Execution.Model.check_context(
      request,
      policy,
      provider,
      opts,
      model_capabilities(run)
    )
  end

  defp check_context(request, _run), do: {:ok, request}

  defp stream_with_retries(provider, request, sink, opts, run, step),
    do:
      Alto.Runner.Execution.Model.stream(
        provider,
        request,
        sink,
        opts,
        model_capabilities(run),
        step
      )

  alias Alto.Runner.Execution.Children
  defp validate_spawn(data), do: Children.validate_spawn(data)

  defp validate_subagent_tools(tools, run),
    do: Children.validate_subagent_tools(tools, Children.project(run))

  defp validate_batch(data, run), do: Children.validate_batch(data, Children.project(run))
  defp subagent_failed(id, reason), do: Children.subagent_failed(id, reason)
  defp subagent_data(id, result), do: Children.subagent_data(id, result)
  defp with_journal(data, journal), do: Children.with_journal(data, journal)
  defp retain_child_outcome(ticket, outcome), do: Children.retain_child_outcome(ticket, outcome)

  defp merge_child_result(run, outcome),
    do: Children.merge(run, Children.merge_child_result(Children.project(run), outcome))

  defp run_children(specs, concurrency, run) do
    case Children.run_children(specs, concurrency, Children.project(run)) do
      {:ok, status, outcomes, journal, state} ->
        {:ok, status, outcomes, journal, Children.merge(run, state)}

      {:error, reason, state} ->
        {:error, reason, Children.merge(run, state)}

      other ->
        other
    end
  end

  defp run_subagent(spec, run) do
    case run_children([spec], 1, run) do
      {:ok, :ok, [{id, outcome}], journal, run} ->
        data = subagent_data(id, outcome) |> with_journal(journal)
        type = if data.status == :error, do: :subagent_failed, else: :subagent_completed
        {:event, Event.durable(type, data), merge_child_result(run, outcome)}

      {:ok, {status, reason}, outcomes, _journal, run} ->
        run =
          Enum.reduce(outcomes, run, fn {_, outcome}, acc -> merge_child_result(acc, outcome) end)

        {status, reason, run}

      {:error, reason, run} ->
        {:error, reason, run}

      {:error, reason} ->
        {:event, subagent_failed(spec.id, reason), run}
    end
  end

  defp run_in_workspace(task, opts, manager, snapshot, identity),
    do:
      Alto.Runner.Execution.Workspace.execute(
        task,
        opts,
        manager,
        snapshot,
        identity,
        &run_without_workspace/2
      )

  defp batch_completed(results, run, journal) do
    data = with_journal(%{results: results}, journal)

    with :ok <- check_native_result(data, run.max_tool_result_bytes),
         {:ok, run} <-
           append_message(run, %{
             "role" => "user",
             "content" =>
               JSON.encode!(%{
                 "type" => "alto_subagent_results",
                 "results" => Alto.Protocol.encode_term(results)
               })
           }) do
      {:event, Event.durable(:subagents_completed, data), run}
    else
      {:error, reason, run} -> {:error, reason, run}
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp complete_model(run, %{message: message, tool_calls: calls} = completion)
       when is_list(calls) do
    cond do
      calls == [] and (not is_binary(message) or message == "") ->
        {:error, :empty_model_response, run}

      true ->
        assistant = assistant_message(message, calls)

        case append_message(run, assistant) do
          {:ok, run} ->
            request_usage = Usage.normalize(Map.get(completion, :usage))
            run = %{run | usage: Usage.merge(run.usage, request_usage)}
            run = add_pending_provider_calls(run, calls)

            event =
              Event.durable(:model_completed, %{
                message: message,
                tool_calls: calls,
                usage: Usage.to_map(request_usage)
              })

            {:event, event, run}

          {:error, reason, run} ->
            {:error, reason, run}
        end
    end
  end

  defp complete_model(run, completion), do: {:error, {:invalid_completion, completion}, run}

  defp add_pending_provider_calls(run, calls) do
    pending =
      Enum.reduce(calls, Map.get(run, :pending_provider_calls, %{}), fn call, pending ->
        key = {Map.get(call, :id), Map.get(call, :name)}
        Map.update(pending, key, 1, &(&1 + 1))
      end)

    Map.put(run, :pending_provider_calls, pending)
  end

  defp check_provider_correlation(run, call_id, name) do
    case Map.get(Map.get(run, :pending_provider_calls, %{}), {call_id, name}) do
      count when is_integer(count) and count > 0 -> :ok
      _other -> {:error, {:uncorrelated_provider_tool_call, call_id, name}}
    end
  end

  defp consume_pending_provider_call(run, call_id, name) do
    key = {call_id, name}
    pending = Map.get(run, :pending_provider_calls, %{})

    pending =
      case Map.get(pending, key) do
        1 -> Map.delete(pending, key)
        count when is_integer(count) and count > 1 -> Map.put(pending, key, count - 1)
        _other -> pending
      end

    Map.put(run, :pending_provider_calls, pending)
  end

  # Exposure enforcement: provider-originated `run_tool` calls must
  # name a tool in the run's effective model exposure; native `invoke_tool`
  # calls use full runtime capabilities and normal approval. Exposure,
  # execution authority, and human approval remain distinct: a hidden tool
  # is still invokable natively, but a fabricated provider call for it fails
  # closed without preparation, approval, or execution.
  defp execute_tool(%{id: call_id, name: name, arguments: arguments}, run, origin, op_id) do
    with {:ok, tool} <- fetch_tool(run.tools, name),
         :ok <- check_model_exposure(name, origin, run) do
      case prepare_tool(tool, arguments, run) do
        {:ok, prepared, details} ->
          case authorize_tool(call_id, name, arguments, details, tool, run, op_id) do
            :ok ->
              run_tool(call_id, name, prepared, tool, run, op_id, origin)

            {:suspend, request} ->
              {:suspend, %{request: request, prepared: prepared, origin: origin}, run}

            {:deny, reason} ->
              tool_failure(
                call_id,
                name,
                {:approval_denied, reason},
                run,
                op_id,
                Outcome.pre_dispatch(reason),
                origin
              )

            {:error, reason} ->
              tool_failure(
                call_id,
                name,
                {:approval_failed, reason},
                run,
                op_id,
                Outcome.pre_dispatch(reason),
                origin
              )

            {:cancelled, reason} ->
              {:cancelled, reason, run}
          end

        {:error, reason} ->
          tool_failure(
            call_id,
            name,
            reason,
            run,
            op_id,
            Outcome.pre_dispatch(reason),
            origin
          )

        {:cancelled, reason} ->
          {:cancelled, reason, run}
      end
    else
      {:error, reason} ->
        tool_failure(
          call_id,
          name,
          reason,
          run,
          op_id,
          Outcome.pre_dispatch(reason),
          origin
        )
    end
  end

  # Runtime operation identity: per-run monotonic counter scoped by the
  # globally unique run id. `call_id` may repeat or be nil; `op_id` never does.
  defp next_operation(run) do
    seq = Map.get(run, :op_seq, 0) + 1
    op_id = "#{run.tool_context.session_id}:op-#{seq}"
    {op_id, Map.put(run, :op_seq, seq)}
  end

  defp check_model_exposure(_name, :native, _run), do: :ok

  defp check_model_exposure(name, :provider, run) when is_binary(name) do
    if MapSet.member?(run.request_model_tools || run.model_tools, name) do
      :ok
    else
      {:error, {:model_tool_not_exposed, name}}
    end
  end

  defp check_model_exposure(name, :provider, _run), do: {:error, {:invalid_tool_name, name}}

  defp tool_capabilities(run) do
    values =
      Map.take(run, [
        :tools,
        :approval,
        :budget,
        :cancel_ref,
        :tool_timeout,
        :approval_timeout,
        :max_approval_details_bytes,
        :max_tool_result_bytes,
        :event_sink
      ])

    struct!(Alto.Runner.Execution.Tool.Capabilities, Map.put(values, :context, run.tool_context))
  end

  defp prepare_tool(tool, args, run),
    do: Alto.Runner.Execution.Tool.prepare(tool, args, tool_capabilities(run))

  defp authorize_tool(call_id, name, args, details, tool, run, op_id),
    do:
      Alto.Runner.Execution.Tool.authorize(
        call_id,
        name,
        args,
        details,
        tool,
        tool_capabilities(run),
        op_id
      )

  defp run_tool(call_id, name, prepared, tool, run, op_id, origin) do
    case cancellation(run.cancel_ref) do
      {:cancelled, reason} ->
        {:cancelled, reason, run}

      :continue ->
        notify(
          run.event_sink,
          Event.live(:tool_started, %{
            call_id: call_id,
            operation_id: op_id,
            run_id: run.tool_context.session_id,
            name: name
          })
        )

        # : remember the dispatched operation so a later cancellation
        # can record uncertainty instead of silence. Cleared on every
        # supervised return; only a cancellation leaves it behind.
        run = Map.put(run, :in_flight, %{call_id: call_id, operation_id: op_id, name: name})

        case Alto.Runner.Execution.Tool.invoke(tool, prepared, tool_capabilities(run)) do
          {:ok, outcome} ->
            tool_outcome(call_id, name, outcome, Map.delete(run, :in_flight), op_id, origin)

          {:error, reason} ->
            tool_failure(
              call_id,
              name,
              reason,
              Map.delete(run, :in_flight),
              op_id,
              Outcome.unknown(reason),
              origin
            )

          {:cancelled, reason} ->
            {:cancelled, reason, run}
        end
    end
  end

  defp tool_outcome(call_id, name, {:ok, value}, run, op_id, origin) do
    # Bounded native result contract: the native `value` is measured
    # with `:erlang.external_size/1` against `max_tool_result_bytes` *before*
    # any event retention, subscriber fanout, or session persistence. An
    # oversize native value is rejected as a bounded `tool_failed` — the tool
    # ran exactly once and that fact is retained; it is never re-executed and
    # the raw value is never stored. `output` is the separate legacy
    # provider-facing encoding (bounded string, truncated with a marker for
    # backward compatibility); deterministic loops must prefer `value`.
    # Provider serialization stays at the provider boundary (transcript
    # messages carry `output` only).
    case check_native_result(value, run.max_tool_result_bytes) do
      :ok ->
        run = merge_verdict(run, :completed)
        content = encode_tool_result(value, run.max_tool_result_bytes)

        case add_outcome_message(run, origin, call_id, name, op_id, :completed, content) do
          {:ok, run} ->
            # `output` is the bounded provider-facing encoding; `value` is the
            # native term for deterministic loops. Provider serialization stays
            # at the provider boundary instead of leaking into loop policy.
            # `call_id` preserves tool-call correlation; `operation_id` is the
            # globally unique runtime operation.
            {:event,
             Event.durable(:tool_completed, %{
               call_id: call_id,
               operation_id: op_id,
               run_id: run.tool_context.session_id,
               name: name,
               output: content,
               value: value,
               outcome: Outcome.completed()
             }), run}

          {:error, reason, run} ->
            {:error, reason, merge_verdict(run, :unknown)}
        end

      {:error, reason} ->
        tool_failure(call_id, name, reason, run, op_id, Outcome.unknown(reason), origin)
    end
  end

  defp tool_outcome(call_id, name, {:error, reason}, run, op_id, origin),
    do:
      tool_failure(
        call_id,
        name,
        reason,
        run,
        op_id,
        Outcome.participant_failed(reason),
        origin
      )

  defp tool_outcome(call_id, name, {:unknown, reason}, run, op_id, origin),
    do: tool_failure(call_id, name, reason, run, op_id, Outcome.unknown(reason), origin)

  defp tool_outcome(call_id, name, other, run, op_id, origin) do
    tool_failure(
      call_id,
      name,
      {:invalid_tool_return, other},
      run,
      op_id,
      Outcome.unknown(other),
      origin
    )
  end

  defp check_native_result(value, limit) do
    size = :erlang.external_size(value)

    if size <= limit do
      :ok
    else
      {:error, {:tool_result_too_large, %{limit: limit, size: size}}}
    end
  end

  # : every tool failure carries an outcome class alongside the reason.
  # Pre-dispatch sites pass `:rejected_before_dispatch` (non-commit proven);
  # the participant's own error passes `:failed_known`; supervision silence
  # (timeout/crash) and uninterpretable returns pass `:unknown`. Event types
  # are unchanged — loops keep matching on type.
  defp tool_failure(call_id, name, reason, run, op_id, outcome, origin) do
    run = merge_verdict(run, outcome)
    content = encode_tool_result(%{error: inspect(reason)}, run.max_tool_result_bytes)
    bounded_reason = bound_failure_reason(reason, run.max_tool_result_bytes)

    case add_outcome_message(run, origin, call_id, name, op_id, :failed, content) do
      {:ok, run} ->
        {:event,
         Event.durable(:tool_failed, %{
           call_id: call_id,
           operation_id: op_id,
           run_id: run.tool_context.session_id,
           name: name,
           error: bounded_reason,
           outcome: outcome
         }), run}

      {:error, limit_reason, run} ->
        {:error, limit_reason, run}
    end
  end

  # Failure reasons are event payload, not merely provider-facing text. Keep
  # the same native-result bound on that retained field so a participant can
  # not fan out an unbounded error through events, loops, or session storage.
  defp bound_failure_reason(reason, limit) do
    size = :erlang.external_size(reason)

    if size <= limit do
      reason
    else
      candidates = [{:tool_failure_too_large, %{limit: limit, size: size}}, :truncated, nil, ""]
      Enum.find(candidates, :truncated, &(:erlang.external_size(&1) <= limit))
    end
  end

  # Provider-originated outcomes are the only values that may become `tool`
  # messages, and only after `interpret/2` proved the call is pending. Native
  # outcomes are independent host effects, so a later model sees them as
  # explicit context rather than an orphan provider-tool reply.
  defp add_outcome_message(
         %{provider: nil} = run,
         _origin,
         _call_id,
         _name,
         _op_id,
         _status,
         _content
       ),
       do: {:ok, run}

  defp add_outcome_message(run, :provider, call_id, name, _op_id, _status, content) do
    message = %{"role" => "tool", "tool_call_id" => call_id, "content" => content}

    case append_message(run, message) do
      {:ok, run} -> {:ok, consume_pending_provider_call(run, call_id, name)}
      error -> error
    end
  end

  defp add_outcome_message(run, :native, call_id, name, op_id, status, content) do
    context =
      JSON.encode!(%{
        "type" => "alto_native_tool_result",
        "call_id" => call_id,
        "operation_id" => op_id,
        "name" => name,
        "status" => Atom.to_string(status),
        "content" => content
      })

    append_message(run, %{"role" => "user", "content" => context})
  end

  defp append_message(run, message) do
    alias Alto.Runner.Execution.Transcript, as: History

    case History.append(History.project(run), message) do
      {:ok, state} -> {:ok, History.merge(run, state)}
      {:error, reason, state} -> {:error, reason, History.merge(run, state)}
    end
  end

  # An empty tool_calls array is not part of the Chat Completions shape, and
  # strict OpenAI-compatible servers reject it.
  defp assistant_message(message, []) do
    %{"role" => "assistant", "content" => message}
  end

  defp assistant_message(message, calls) do
    %{
      "role" => "assistant",
      "content" => message,
      "tool_calls" =>
        Enum.map(calls, fn call ->
          %{
            "id" => call.id,
            "type" => "function",
            "function" => %{"name" => call.name, "arguments" => call.arguments_json}
          }
        end)
    }
  end

  defp decode_arguments(""), do: {:ok, %{}}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:tool_arguments_not_object, decoded}}
      {:error, error} -> {:error, {:invalid_tool_arguments, Exception.message(error)}}
    end
  end

  defp decode_arguments(arguments), do: {:error, {:invalid_tool_arguments, arguments}}

  defp fetch_tool(tools, name) when is_binary(name) do
    case Map.fetch(tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  defp fetch_tool(_tools, name), do: {:error, {:invalid_tool_name, name}}

  defp supervised_call(fun, timeout, cancel_ref),
    do: Alto.Runner.Execution.Call.run(fun, timeout, cancel_ref)

  defp cancellation(ref), do: Alto.Runner.Execution.Call.cancellation(ref)

  defp cancelled(reason, run) do
    in_flight =
      case Map.get(run, :in_flight) do
        nil ->
          nil

        %{call_id: call_id, operation_id: op_id, name: name} ->
          %{call_id: call_id, operation_id: op_id, name: name, outcome: Outcome.unknown(reason)}
      end

    run =
      record_event(run, Event.durable(:run_cancelled, %{reason: reason, in_flight: in_flight}))

    {:error, {:cancelled, reason}, result(run, nil, :cancelled)}
  end

  defp record_event(run, event) do
    state =
      Alto.Runner.Execution.Events.project(run) |> Alto.Runner.Execution.Events.record(event)

    Alto.Runner.Execution.Events.merge(run, state)
  end

  defp persist_session_outcome(run, outcome) do
    state = Alto.Runner.Execution.Session.from_run(run)
    Alto.Runner.Execution.Session.persist_outcome(state, outcome)
  end

  defp persistence_status([]), do: :ok
  defp persistence_status(errors), do: {:degraded, errors}

  defp normalize_session_opt(nil), do: {:ok, nil}
  defp normalize_session_opt(:new), do: {:ok, Session.generate_id()}

  defp normalize_session_opt(id) when is_binary(id) do
    case Session.validate_id(id) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_session_opt(other), do: {:error, {:invalid_session_option, other}}

  defp generate_run_id do
    "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp notify(sink, event) do
    sink.(event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp encode_tool_result(value, limit) do
    encoded = if is_binary(value), do: value, else: JSON.encode!(value)
    bound_tool_result(encoded, limit)
  rescue
    # A non-encodable tool result stays a bounded tool message; letting it
    # grow unbounded would trip the transcript limit and fail the whole run.
    error ->
      bound_tool_result(inspect(%{encoding_error: Exception.message(error), value: value}), limit)
  end

  defp bound_tool_result(encoded, limit) do
    if byte_size(encoded) <= limit do
      encoded
    else
      String.slice(encoded, 0, limit) <> "\n[alto: tool result truncated]"
    end
  end

  defp new_run(task, opts) do
    # Account attachment can perform storage I/O before a context exists.
    # Bound that initialization too, and allow its owner to cancel the wait.
    if Keyword.get(opts, :budget_account) do
      timeout = Keyword.get(opts, :run_timeout, 900_000)

      if is_integer(timeout) and timeout > 0 do
        case supervised_call(
               fn -> Alto.Runner.Execution.Setup.open(task, opts) end,
               timeout,
               Keyword.get(opts, :cancel_ref)
             ) do
          {:ok, result} -> result
          {:cancelled, reason} -> {:error, {:cancelled, reason}}
          {:error, :timeout} -> {:error, :run_timeout}
          {:error, reason} -> {:error, {:budget_account_unavailable, reason}}
        end
      else
        {:error, {:invalid_option, :run_timeout, timeout}}
      end
    else
      Alto.Runner.Execution.Setup.open(task, opts)
    end
  end

  defp runtime_context(run),
    do: %{
      session_id: run.tool_context.session_id,
      cwd: run.tool_context.cwd,
      agent_identity: run.tool_context.agent_identity
    }

  defp result(run, output, disposition) do
    %Result{
      output: output,
      loop_state: run.loop_state,
      messages: Enum.reverse(run.messages_rev),
      events: Enum.reverse(run.events_rev),
      events_dropped: run.events_dropped,
      verdict: final_verdict(run.verdict, disposition),
      model_requests: run.model_requests,
      transcript_bytes: run.transcript_bytes,
      session_id: run.session,
      run_id: run.tool_context.session_id,
      agent_identity: run.tool_context.agent_identity,
      usage: Usage.to_map(run.usage),
      persistence: persistence_status(Enum.reverse(run.persistence_errors))
    }
  end

  defp empty_result(session_id) do
    %Result{
      output: nil,
      loop_state: nil,
      messages: [],
      events: [],
      events_dropped: 0,
      verdict: :empty,
      model_requests: 0,
      transcript_bytes: 0,
      session_id: session_id,
      run_id: nil,
      usage: Usage.to_map(Usage.new()),
      persistence: :not_requested
    }
  end

  defp merge_verdict(run, class) do
    events =
      Alto.Runner.Execution.Events.project(run)
      |> Alto.Runner.Execution.Events.merge_verdict(class)

    Alto.Runner.Execution.Events.merge(run, events)
  end

  defp final_verdict(:empty, :success), do: :completed
  defp final_verdict(:empty, _disposition), do: :rejected_before_dispatch
  defp final_verdict(:completed, disposition) when disposition != :success, do: :unknown
  defp final_verdict(verdict, _disposition), do: verdict
end
