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
    @type t :: %__MODULE__{effects: [Alto.Effect.t()], terminal: Alto.Transition.status()}
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

  alias Alto.Runner.Execution.{Call, Children, Events, Model, Operation}
  alias Alto.Runner.Execution.Transcript, as: RunTranscript
  alias Alto.Runner.Execution.Session, as: RunSession
  alias Alto.Effect
  alias Alto.Event
  alias Alto.Runner.Result
  alias Alto.Runner.Execution.History
  alias Alto.Runtime
  alias Alto.Session
  alias Alto.Transition
  alias Alto.Usage
  alias Alto.Context.Transcript
  alias Alto.Runner.Budget

  require Logger

  @type provider_spec :: module() | {module(), keyword()}
  @type approval_spec :: module() | {module(), keyword()}
  @type run_result :: {:ok, Result.t()} | {:error, term(), Result.t()}

  @spec run(term(), keyword(), (Frame.t(), context() -> run_result())) :: run_result()
  def run(task, opts, scheduler) do
    case Keyword.get(opts, :input) do
      nil ->
        run_scoped(task, opts, scheduler)

      input ->
        case claim_input(input) do
          :ok ->
            try do
              run_scoped(task, opts, scheduler)
            after
              try do
                Alto.Input.release(input)
              catch
                :exit, _ -> :ok
              end
            end

          {:error, reason} ->
            {:error, reason, Result.empty()}
        end
    end
  end

  defp claim_input(input) do
    Alto.Input.claim(input)
  catch
    :exit, reason -> {:error, {:input_unavailable, reason}}
  end

  defp run_scoped(task, opts, scheduler) do
    opts = Keyword.put(opts, :execution_scheduler, scheduler)

    outcome =
      case Keyword.pop(opts, :workspace_assignment) do
        {nil, opts} ->
          run_without_workspace(task, opts)

        {{manager, snapshot, identity}, opts} ->
          run_in_workspace(task, opts, manager, snapshot, identity)
      end

    Children.retain_child_outcome(Keyword.get(opts, :subagent_ticket), outcome)
  end

  defp run_without_workspace(task, opts) do
    case Alto.Runner.Execution.Parent.options(opts) do
      {:ok, opts} -> run_with_options(task, opts)
      {:error, reason} -> {:error, reason, Result.empty(nil)}
    end
  end

  defp run_with_options(task, opts) do
    opts =
      case Keyword.get(opts, :checkpoint) do
        {%{"session_id" => session}, _decision} -> Keyword.put(opts, :session, session)
        _ -> opts
      end

    case normalize_session_opt(Keyword.get(opts, :session)) do
      {:ok, session} ->
        opts = Keyword.put(opts, :session, session)

        case new_run(task, opts) |> History.initialize(opts) do
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

            outcome = schedule_outcome(outcome, opts)

            RunSession.persist_outcome(run, outcome)

          {:error, {:cancelled, reason}} ->
            event = Event.durable(:run_cancelled, %{reason: reason})
            Alto.Events.notify(Keyword.get(opts, :event_sink, fn _ -> :ok end), event)
            {:error, {:cancelled, reason}, %{Result.empty(session) | events: [event]}}

          {:error, reason} ->
            {:error, reason, Result.empty(session)}
        end

      {:error, reason} ->
        {:error, reason, Result.empty(nil)}
    end
  end

  defp schedule_outcome({:continue, frame, context}, opts),
    do: Keyword.fetch!(opts, :execution_scheduler).(frame, context)

  defp schedule_outcome({:done, outcome}, _opts), do: outcome
  defp schedule_outcome(outcome, _opts), do: outcome

  defp drive(%Transition{} = transition, run, remaining_effects) do
    run = %{run | loop_state: transition.state}

    effects =
      transition.effects ++ if(transition.status == :continue, do: remaining_effects, else: [])

    execute(effects, run, transition.status)
  end

  defp execute(effects, run, terminal),
    do: {:continue, %Frame{effects: effects, terminal: terminal}, run}

  @doc "Execute at most one effect, returning the next frame or a final outcome."
  def step(%Frame{effects: effects, terminal: terminal}, run) do
    case {Call.cancellation(run.cancel_ref), Budget.check(run.budget)} do
      {{:cancelled, reason}, _} -> {:done, cancelled(reason, run)}
      {_, {:error, reason}} -> {:done, {:error, reason, result(run, nil, :error)}}
      {:continue, :ok} -> admit_input(effects, run, terminal)
    end
  end

  defp admit_input(effects, %{input: input} = run, terminal) when not is_nil(input) do
    modes =
      cond do
        effects == [] and match?({:stop, _}, terminal) -> [:steer, :follow_up]
        match?([%Effect{kind: :request_model} | _], effects) -> [:steer]
        true -> []
      end

    if modes != [] and map_size(Map.get(run, :pending_provider_calls, %{})) == 0 do
      case Alto.Input.peek(input, modes, max(Budget.remaining(run.budget), 1)) do
        nil ->
          do_execute(effects, run, terminal)

        {:error, reason} ->
          {:done, {:error, reason, result(run, nil, :error)}}

        entry ->
          case RunTranscript.append(run, %{"role" => "user", "content" => entry.text}) do
            {:ok, next} ->
              :ok = Alto.Input.ack(input, entry.id, max(Budget.remaining(run.budget), 1))
              event = Event.durable(:input_received, entry)

              rest =
                case effects do
                  [%Effect{kind: :request_model} | rest] -> rest
                  [] -> []
                end

              finish_effect({:event, event, next}, rest, next, :continue)

            {:error, reason, next} ->
              {:done, {:error, reason, result(next, nil, :error)}}
          end
      end
    else
      do_execute(effects, run, terminal)
    end
  catch
    :exit, reason -> {:done, {:error, {:input_unavailable, reason}, result(run, nil, :error)}}
  end

  defp admit_input(effects, run, terminal), do: do_execute(effects, run, terminal)

  defp do_execute([], run, {:stop, output}), do: {:done, {:ok, result(run, output, :success)}}

  defp do_execute([], run, {:error, reason}),
    do: {:done, {:error, reason, result(run, nil, :error)}}

  defp do_execute([], run, :continue),
    do: {:done, {:error, :loop_stalled, result(run, nil, :error)}}

  defp do_execute(
         [
           %Effect{kind: :run_tools, data: %{calls: [_ | _] = calls, max_concurrency: limit}}
           | rest
         ],
         run,
         terminal
       )
       when is_list(calls) and limit in 1..32 do
    group = calls |> Enum.take(limit) |> Enum.take_while(&parallel_call?(&1, run))
    pending = Enum.drop(calls, max(1, length(group)))
    rest = if pending == [], do: rest, else: [Effect.run_tools(pending, limit) | rest]

    # Approval and exclusive calls remain ordinary effects. The remaining batch
    # stays in its public representation even when an approval suspends execution.
    case group do
      [] -> do_execute([Effect.run_tool(hd(calls)) | rest], run, terminal)
      group -> run_batch(group, run, rest, terminal)
    end
  end

  defp do_execute([%Effect{kind: :run_tools} | _], run, _terminal),
    do: {:done, {:error, :invalid_tool_batch, result(run, nil, :error)}}

  defp do_execute(
         [%Effect{kind: :spawn_agents, data: data} | rest],
         %{continuation_store: store, budget: %{account: %Budget.Account{}}, agent_depth: 0} =
           run,
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
    case Call.run(
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
        with {:ok, next_run} <- History.persist(next_run, allow_pending: true) do
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
        else
          {:error, reason, next_run} -> {:done, {:error, reason, result(next_run, nil, :error)}}
        end

      {:error, reason} ->
        {:done, {:error, reason, result(run, nil, :error)}}

      {:ok, next_run} ->
        execute(rest, next_run, terminal)

      {:event, event, next_run} ->
        dispatch_batch([event], Events.record(next_run, event), [], rest, :continue)

      {:events, events, next_run} ->
        dispatch_batch(events, next_run, [], rest, terminal)

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
         {:ok, tool} <- fetch_tool(restored.tools, frame.pending.name) do
      resume_validated(restored, frame, tool, decision, opts)
    else
      {:error, reason} -> ungranted_checkpoint(run, reason)
    end
  end

  defp resume_validated(run, frame, tool, decision, opts) do
    case Keyword.get(opts, :workspace_resume) do
      nil ->
        case claim_child_checkpoint(run, decision) do
          :ok -> execute_checkpoint(run, frame, tool, decision)
          {:error, reason} -> ungranted_checkpoint(run, reason)
        end

      {manager, id, revision} ->
        Alto.Runner.Execution.Workspace.resume_checkpoint(
          opts,
          manager,
          id,
          revision,
          fn workspace ->
            with true <- workspace["cwd"] == run.tool_context.cwd,
                 :ok <- claim_child_checkpoint(run, decision) do
              {:ok, nil}
            else
              false -> {:error, {:checkpoint_admission_failed, :child_workspace_mismatch}}
              {:error, reason} -> {:error, {:checkpoint_admission_failed, reason}}
            end
          end,
          fn _, _ ->
            execute_checkpoint(run, frame, tool, decision) |> schedule_outcome(opts)
          end
        )
        |> case do
          {:error, {:checkpoint_admission_failed, reason}} -> ungranted_checkpoint(run, reason)
          outcome -> outcome
        end
    end
  end

  defp execute_checkpoint(run, frame, tool, decision) do
    job = frame.pending

    interpreted =
      if decision == :approve do
        job = Map.merge(job, %{tool: tool, summary: tool_summary(run, job.name, job.arguments)})
        dispatch_tool_job(job, run)
      else
        finish_tool_job(job, {:rejected, {:approval_denied, :user}}, run)
      end

    finish_effect(interpreted, frame.remaining, run, frame.terminal)
  end

  defp ungranted_checkpoint(run, reason) do
    value = result(run, nil, :error)

    value =
      if run.child_resume,
        do: %{value | checkpoint: %{"kind" => "child", "ungranted" => true}},
        else: value

    {:error, reason, value}
  end

  defp claim_child_checkpoint(%{child_resume: nil}, _decision), do: :ok

  defp claim_child_checkpoint(run, decision) do
    case checkpoint_call(
           fn ->
             Alto.Subagents.Continuation.claim_child(
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
    case Call.run(fun, Budget.timeout(run.budget, 30_000), run.cancel_ref) do
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
    case Call.run(fun, Budget.timeout(run.budget, 30_000), run.cancel_ref) do
      {:ok, %Transition{} = transition} -> {:ok, transition}
      {:ok, other} -> {:error, {:invalid_transition, other}}
      {:error, reason} -> {:error, {:loop_process_failed, reason}}
      {:cancelled, reason} -> {:cancelled, reason}
    end
  end

  defp interpret(%Effect{kind: :emit, data: %{event: %Event{} = event}}, run) do
    {:event, event, run}
  end

  defp interpret(%Effect{kind: :compact_context, data: options}, run) do
    RunTranscript.reduce(run,
      reason: :manual,
      required_headroom: Map.get(options, :required_headroom, 0)
    )
  end

  defp interpret(%Effect{kind: :request_model}, %{provider: nil} = run),
    do: {:error, :provider_required, run}

  defp interpret(%Effect{kind: :request_model, data: request}, run) do
    with {:ok, run} <- request_context(request, run),
         :ok <- Transcript.validate(Enum.reverse(run.messages_rev)),
         {:ok, request, run} <- prepare_model_context(request, run),
         {:ok, run} <- History.persist(run) do
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
    {op_id, run} = Operation.next(run)
    name = Map.get(call, :name)

    prepare_and_run_tool(call, :json, tool_origin(run, Map.get(call, :id), name), op_id, run)
  end

  # Native invocation from loops and hooks: arguments are already a map.
  defp interpret(%Effect{kind: :invoke_tool, data: call}, run) do
    {op_id, run} = Operation.next(run)
    prepare_and_run_tool(call, :native, :native, op_id, run)
  end

  defp interpret(%Effect{kind: :spawn_agents, data: data}, run) do
    with {:ok, specs, concurrency} <- Children.validate_batch(data, run),
         {:ok, results, journal, run} <- spawn_agents(specs, concurrency, run) do
      batch_completed(results, run, journal)
    else
      {:error, reason} -> {:error, {:invalid_spawn_agents, reason}, run}
      {:cancelled, reason} -> {:cancelled, reason, run}
      other -> other
    end
  end

  defp interpret(%Effect{} = effect, run), do: {:error, {:unknown_effect, effect.kind}, run}

  defp spawn_agents(specs, concurrency, run) do
    with {:ok, status, outcomes, journal, run} <- Children.run_children(specs, concurrency, run) do
      {results, run} =
        Enum.map_reduce(outcomes, run, fn {id, outcome}, acc ->
          summary = Children.child_summary(id, outcome)
          {Children.public_child_summary(summary), Children.merge_child_summary(acc, summary)}
        end)

      case status do
        :ok -> {:ok, results, journal, run}
        {:cancelled, reason} -> {:cancelled, reason, run}
        {:error, reason} -> {:error, reason, run}
      end
    else
      {:error, reason, run} -> {:error, reason, run}
      {:error, reason} -> {:error, {:invalid_spawn_agents, reason}, run}
      {:cancelled, reason} -> {:cancelled, reason, run}
    end
  end

  defp request_context(request, run) do
    case Map.fetch(request, :context_message) do
      :error ->
        {:ok, run}

      {:ok, content} when is_binary(content) ->
        if String.valid?(content),
          do: RunTranscript.append(run, %{"role" => "user", "content" => content}),
          else: {:error, :invalid_context_message}

      _ ->
        {:error, :invalid_context_message}
    end
  end

  defp prepare_model_context(effect_request, run) do
    with {:ok, request} <- model_request(effect_request, run) do
      checked = check_context(request, run)

      case checked do
        {:ok, %{context_pressure: true} = request} ->
          compact_model_context(
            effect_request,
            run,
            {:ok, Map.delete(request, :context_pressure)}
          )

        {:error, {:context_limit, _}} ->
          compact_model_context(effect_request, run, checked)

        {status, value} ->
          {status, value, run}
      end
    end
  end

  defp compact_model_context(effect_request, run, {status, fallback}) do
    case RunTranscript.reduce(run, reason: :model_context_pressure) do
      {:ok, next} -> prepare_model_context(effect_request, next)
      {:error, {:cancelled, _} = reason, next} -> {:error, reason, next}
      {:error, _, next} -> {status, fallback, next}
    end
  end

  defp request_model(request, run) do
    if run.model_requests >= run.max_steps do
      {:error, {:model_step_limit, run.max_steps}, run}
    else
      live_sink = fn event -> Alto.Events.notify(run.event_sink, event) end
      {provider, provider_opts} = run.provider
      step = run.model_requests + 1

      Alto.Events.notify(
        run.event_sink,
        Event.live(:model_started, %{step: step})
      )

      outcome =
        Model.stream(provider, request, live_sink, provider_opts, run, step)

      run = %{run | model_requests: run.model_requests + 1}

      case outcome do
        {:ok, {:ok, completion}} ->
          usage = Usage.normalize(if(is_map(completion), do: Map.get(completion, :usage)))

          observation = Alto.Context.Observation.new(request, usage.input_tokens)

          complete_model(Map.put(run, :context_observation, observation), completion)

        {:ok, {:error, reason}} ->
          {:error, {:model_request_failed, reason}, run}

        {:error, reason} ->
          {:error, {:model_process_failed, reason}, run}

        {:cancelled, reason} ->
          {:cancelled, reason, run}
      end
    end
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
           session_id: run.session || run.tool_context.session_id,
           context_observation: Map.get(run, :context_observation),
           resume_context_observation: Map.get(run, :resume_context_observation),
           tools: tools,
           options: Map.new(options, fn {key, value} -> {to_string(key), value} end),
           loop: request
         }}
    end
  end

  defp check_context(request, %{spec: %{context: nil}}), do: {:ok, request}

  defp check_context(request, %{spec: %{context: policy}} = run) do
    {provider, opts} = run.provider

    Alto.Runner.Execution.Model.check_context(
      request,
      policy,
      provider,
      opts,
      run
    )
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
    data = Children.with_journal(%{results: results}, journal)

    with :ok <-
           Alto.Runner.Execution.Tool.check_native_result(data, run.max_tool_result_bytes),
         {:ok, run} <-
           RunTranscript.append(run, %{
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
        fields =
          Map.take(
            Map.get(completion, :provider_fields, %{}),
            ["reasoning", "reasoning_content", "reasoning_details", "alto_anthropic_content"]
          )

        assistant = Map.merge(assistant_message(message, calls), fields)

        case RunTranscript.append(run, assistant) do
          {:ok, run} ->
            request_usage = Usage.normalize(Map.get(completion, :usage))
            run = %{run | usage: Usage.merge(run.usage, request_usage)}
            run = add_pending_provider_calls(run, calls)

            event =
              Event.durable(:model_completed, %{
                message: message,
                reasoning: Map.get(completion, :reasoning),
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

  defp prepare_and_run_tool(call, encoding, origin, op_id, run) do
    case prepare_tool_job(call, encoding, origin, op_id, run) do
      {:ok, job, details} ->
        case Alto.Runner.Execution.Tool.authorize(job, details, run) do
          :ok ->
            dispatch_tool_job(job, run)

          {:suspend, request} ->
            {:suspend, %{request: request, job: Map.drop(job, [:tool, :summary])}, run}

          {:deny, reason} ->
            finish_tool_job(job, {:rejected, {:approval_denied, reason}}, run)

          {:error, reason} ->
            finish_tool_job(job, {:rejected, {:approval_failed, reason}}, run)

          {:cancelled, reason} ->
            {:cancelled, reason, run}
        end

      {:error, reason, job} ->
        finish_tool_job(job, {:rejected, reason}, run)

      {:cancelled, reason} ->
        {:cancelled, reason, run}
    end
  end

  defp prepare_tool_job(call, encoding, origin, op_id, run) do
    job = %{id: Map.get(call, :id), name: Map.get(call, :name), origin: origin, op_id: op_id}

    with {:ok, arguments} <- tool_arguments(call, encoding),
         {:ok, tool} <- fetch_tool(run.tools, job.name),
         :ok <- check_model_exposure(job.name, origin, run),
         {:ok, prepared, details} <-
           Alto.Runner.Execution.Tool.prepare(tool, arguments, run),
         {:ok, prepared} <- prepare_agent_tool(tool, prepared, run) do
      {:ok,
       Map.merge(job, %{
         arguments: arguments,
         tool: tool,
         prepared: prepared,
         summary: tool_summary(run, job.name, arguments)
       }), details}
    else
      {:cancelled, reason} -> {:cancelled, reason}
      {:error, reason} -> {:error, reason, job}
    end
  end

  defp prepare_agent_tool(%{module: Alto.Tools.SpawnAgents, opts: opts}, prepared, run),
    do: Alto.Subagents.Models.prepare(prepared, run, opts)

  defp prepare_agent_tool(_tool, prepared, _run), do: {:ok, prepared}

  defp tool_arguments(call, :json), do: decode_arguments(Map.get(call, :arguments_json, "{}"))

  defp tool_arguments(call, :native) do
    case Map.get(call, :arguments) do
      arguments when is_map(arguments) -> {:ok, arguments}
      arguments -> {:error, {:tool_arguments_not_map, arguments}}
    end
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

  defp tool_origin(run, id, name),
    do: if(check_provider_correlation(run, id, name) == :ok, do: :provider, else: :native)

  defp parallel_call?(%{name: name}, run) do
    case Map.get(run.tools, name) do
      %{execution_mode: :parallel, approval: :never} -> true
      _ -> false
    end
  end

  defp parallel_call?(_, _), do: false

  defp run_batch(calls, run, rest, terminal) do
    interpreted =
      with {:ok, jobs_rev, run} <- prepare_batch(calls, run),
           do: dispatch_tool_jobs(Enum.reverse(jobs_rev), run)

    finish_effect(interpreted, rest, run, terminal)
  end

  defp dispatch_tool_jobs(jobs, run) do
    ready = Enum.filter(jobs, &Map.has_key?(&1, :prepared))

    with {:ok, run} <- begin_tool_jobs(ready, run) do
      response = Alto.Runner.ToolBatch.run(Enum.map(ready, &{&1.tool, &1.prepared}), run)

      {outcomes, stopped} =
        case response do
          {:ok, outcomes} -> {outcomes, nil}
          {:cancelled, reason, outcomes} -> {outcomes, {:cancelled, reason}}
          {:error, reason, outcomes} -> {outcomes, reason}
        end

      indexed = Map.new(Enum.zip(Enum.map(ready, & &1.op_id), outcomes))
      outcomes = Enum.map(jobs, &Map.get(indexed, &1.op_id, {:rejected, &1[:error]}))
      finish_tool_jobs(jobs, outcomes, run, stopped)
    end
  end

  defp prepare_batch(calls, run) do
    Enum.reduce_while(calls, {:ok, [], run}, fn call, {:ok, jobs, run} ->
      case reserve_effect(run) do
        :ok ->
          {op_id, run} = Operation.next(run)
          name = Map.get(call, :name)
          id = Map.get(call, :id)

          origin = tool_origin(run, id, name)

          case prepare_tool_job(call, :json, origin, op_id, run) do
            {:cancelled, reason} ->
              {:halt, {:error, {:cancelled, reason}, run}}

            {:ok, job, _details} ->
              {:cont, {:ok, [job | jobs], run}}

            {:error, reason, job} ->
              {:cont, {:ok, [Map.put(job, :error, reason) | jobs], run}}
          end

        {:error, reason} ->
          {:halt, {:error, reason, run}}

        {:cancelled, reason, next} ->
          {:halt, {:error, {:cancelled, reason}, next}}
      end
    end)
  end

  defp finish_tool_jobs(jobs, outcomes, run, stopped) do
    # All worker outcomes are folded before any middleware-generated effect
    # executes. Each invocation is correlated and accounted exactly once.
    {run, events, failure} =
      Enum.zip(jobs, outcomes)
      |> Enum.reduce({run, [], nil}, fn {job, outcome}, {run, events, failure} ->
        interpreted = finish_tool_job(job, outcome, run)

        case interpreted do
          {:event, event, next} -> {Events.record(next, event), [event | events], failure}
          {:error, reason, next} -> {next, events, failure || reason}
        end
      end)

    case stopped || failure do
      nil ->
        {:events, Enum.reverse(events), run}

      reason ->
        {:error, reason, run}
    end
  end

  defp dispatch_batch([], run, effects, rest, terminal),
    do: execute(effects ++ rest, run, terminal)

  defp dispatch_batch([event | events], run, effects, rest, terminal) do
    case call_policy(
           fn -> Runtime.dispatch(run.spec, event, run.loop_state, runtime_context(run)) end,
           run
         ) do
      {:ok, transition} ->
        next = %{run | loop_state: transition.state}

        case transition.status do
          :continue -> dispatch_batch(events, next, effects ++ transition.effects, rest, terminal)
          terminal -> execute(effects ++ transition.effects, next, terminal)
        end

      {:cancelled, reason} ->
        {:done, cancelled(reason, run)}

      {:error, reason} ->
        {:done, {:error, reason, result(run, nil, :error)}}
    end
  end

  defp begin_tool_jobs(jobs, run) do
    with :continue <- Call.cancellation(run.cancel_ref),
         {:ok, run} <- History.dispatch(run, Enum.map(jobs, & &1.op_id)) do
      Enum.each(jobs, &notify_tool_started(&1, run))
      {:ok, run}
    else
      {:cancelled, reason} -> {:cancelled, reason, run}
      error -> error
    end
  end

  defp notify_tool_started(job, run) do
    Alto.Events.notify(
      run.event_sink,
      Event.live(:tool_started, %{
        call_id: job.id,
        operation_id: job.op_id,
        run_id: run.tool_context.session_id,
        name: job.name,
        summary: job.summary
      })
    )
  end

  defp dispatch_tool_job(%{tool: %{module: Alto.Tools.SpawnAgents}} = job, run) do
    with {:ok, specs, concurrency} <- Children.validate_batch(job.prepared, run),
         {:ok, run} <- begin_tool_jobs([job], run) do
      case spawn_agents(specs, concurrency, run) do
        {:ok, results, journal, next} ->
          value = Children.with_journal(%{results: results}, journal)

          outcome =
            Alto.Runner.Execution.Tool.bound_result({:ok, value}, next.max_tool_result_bytes)

          finish_tool_job(job, {:ok, outcome}, next)

        {:error, reason, next} ->
          finish_tool_job(job, {:error, reason}, next)

        {:cancelled, reason, next} ->
          {:cancelled, reason, next}
      end
    else
      {:error, reason} -> finish_tool_job(job, {:rejected, reason}, run)
      other -> other
    end
  end

  defp dispatch_tool_job(job, run), do: dispatch_tool_jobs([job], run)

  defp finish_tool_job(job, {:ok, outcome}, run) do
    tool_outcome(job, outcome, run)
    |> tool_event_summary(job.summary)
  end

  defp finish_tool_job(job, {:rejected, reason}, run),
    do: tool_failure(job, reason, :rejected_before_dispatch, run)

  defp finish_tool_job(job, {:error, reason}, run),
    do: tool_failure(job, reason, :unknown, run)

  defp tool_event_summary({:event, event, run}, summary),
    do: {:event, %{event | data: Map.put(event.data, :summary, summary)}, run}

  defp tool_event_summary(other, _summary), do: other

  defp tool_outcome(job, {:ok, value}, run) do
    # Workers bound native values before returning them. Provider content has
    # a separate encoding bound and is not duplicated in the completion event.
    with {:ok, content} <- model_result_content(value, run) do
      commit_tool_outcome(
        job,
        content,
        %{value: value, outcome: :completed},
        run
      )
    else
      {:error, reason} ->
        tool_failure(job, reason, :unknown, run)
    end
  end

  defp tool_outcome(job, {:error, reason}, run),
    do: tool_failure(job, reason, :failed_known, run)

  defp tool_outcome(job, {:unknown, reason}, run), do: tool_failure(job, reason, :unknown, run)

  defp tool_outcome(job, other, run),
    do: tool_failure(job, {:invalid_tool_return, other}, :unknown, run)

  # : every tool failure carries an outcome class alongside the reason.
  # Pre-dispatch sites pass `:rejected_before_dispatch` (non-commit proven);
  # the participant's own error passes `:failed_known`; supervision silence
  # (timeout/crash) and uninterpretable returns pass `:unknown`. Event types
  # are unchanged — loops keep matching on type.
  defp tool_failure(job, reason, outcome, run) do
    bounded_reason = bound_failure_reason(reason, run.max_tool_result_bytes)

    content =
      encode_tool_result(
        %{error: Alto.Protocol.encode_term(bounded_reason)},
        run.max_tool_result_bytes
      )

    commit_tool_outcome(
      job,
      content,
      %{error: bounded_reason, outcome: outcome},
      run
    )
  end

  defp commit_tool_outcome(job, content, %{outcome: outcome} = data, run) do
    {type, status} =
      if outcome == :completed,
        do: {:tool_completed, :completed},
        else: {:tool_failed, :failed}

    run = Events.merge_verdict(run, outcome)

    case add_outcome_message(run, job, status, content) do
      {:ok, run} ->
        run =
          if outcome == :rejected_before_dispatch,
            do: run,
            else: History.resolve(run, job.op_id)

        common = %{
          call_id: job.id,
          operation_id: job.op_id,
          run_id: run.tool_context.session_id,
          name: job.name
        }

        {:event, Event.durable(type, Map.merge(common, data)), run}

      {:error, reason, run} ->
        run = if outcome == :completed, do: Events.merge_verdict(run, :unknown), else: run
        {:error, reason, run}
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
  defp add_outcome_message(%{provider: nil} = run, _job, _status, _content), do: {:ok, run}

  defp add_outcome_message(run, %{origin: :provider} = job, _status, content) do
    message = %{"role" => "tool", "tool_call_id" => job.id, "content" => content}

    case RunTranscript.append(run, message) do
      {:ok, run} -> {:ok, consume_pending_provider_call(run, job.id, job.name)}
      error -> error
    end
  end

  defp add_outcome_message(run, %{origin: :native} = job, status, content) do
    metadata = %{
      type: "alto_native_tool_result",
      call_id: job.id,
      name: job.name,
      operation_id: job.op_id,
      status: status
    }

    content =
      if is_list(content),
        do: [%{"type" => "text", "text" => JSON.encode!(metadata)} | content],
        else: JSON.encode!(Map.put(metadata, :content, content))

    RunTranscript.append(run, %{"role" => "user", "content" => content})
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

  defp cancelled(reason, run) do
    run = Events.record(run, Event.durable(:run_cancelled, %{reason: reason}))
    {:error, {:cancelled, reason}, result(run, nil, :cancelled)}
  end

  defp normalize_session_opt(nil), do: {:ok, nil}
  defp normalize_session_opt(:new), do: {:ok, Session.generate_id()}

  defp normalize_session_opt(id) when is_binary(id) do
    with :ok <- Session.validate_id(id), do: {:ok, id}
  end

  defp normalize_session_opt(other), do: {:error, {:invalid_session_option, other}}

  defp tool_summary(run, name, arguments) do
    present(
      run,
      fn -> Alto.ToolPresentation.summary(run.tool_presenter, name, arguments) end,
      to_string(name || "tool"),
      500
    )
  end

  defp present(%{tool_presenter: nil}, _callback, fallback, _limit), do: fallback

  defp present(run, callback, fallback, limit) do
    case Call.run(callback, Budget.timeout(run.budget, run.tool_timeout), run.cancel_ref) do
      {:ok, text} when is_binary(text) ->
        Alto.Text.prefix(text, limit)

      {:cancelled, reason} ->
        send(self(), {:alto_cancel, run.cancel_ref, reason})
        fallback

      _ ->
        fallback
    end
  end

  defp model_result_content(_value, %{provider: nil}), do: {:ok, nil}

  defp model_result_content(value, run) do
    case Alto.Content.normalize_tool_result(value, run.max_tool_result_bytes) do
      :not_content -> {:ok, encode_tool_result(value, run.max_tool_result_bytes)}
      result -> result
    end
  end

  defp encode_tool_result(value, limit) do
    encoded = if is_binary(value), do: value, else: JSON.encode!(value)
    bound_tool_result(encoded, limit)
  rescue
    # Normalize unsupported terms without replacing the surrounding result shape.
    _error ->
      value
      |> Alto.Protocol.encode_term()
      |> JSON.encode!()
      |> bound_tool_result(limit)
  end

  defp bound_tool_result(encoded, limit),
    do: Alto.Text.truncate(encoded, limit, "\n[alto: tool result truncated]")

  defp new_run(task, opts) do
    # Account attachment can perform storage I/O before a context exists.
    # Bound that initialization too, and allow its owner to cancel the wait.
    if Keyword.get(opts, :budget_account) do
      timeout = Keyword.get(opts, :run_timeout, 900_000)

      if is_integer(timeout) and timeout > 0 do
        case Call.run(
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
    messages = Enum.reverse(run.messages_rev)

    %Result{
      output: output,
      loop_state: run.loop_state,
      messages: messages,
      events: Enum.reverse(run.events_rev),
      events_dropped: run.events_dropped,
      verdict: final_verdict(run.verdict, disposition),
      model_requests: run.model_requests,
      transcript_bytes: run.transcript_bytes,
      session_id: run.session,
      run_id: run.tool_context.session_id,
      agent_identity: run.tool_context.agent_identity,
      transcript_revision: run.transcript_revision,
      context_observation:
        Alto.Context.Observation.dump(Map.get(run, :context_observation), messages),
      resolved_operations: Map.get(run, :resolved_operations, []),
      transcript_persisted:
        Map.get(run, :history_digest) ==
          :crypto.hash(:sha256, :erlang.term_to_binary(run.messages_rev, [:deterministic])) and
          Map.get(run, :resolved_operations, []) == [],
      usage: Usage.to_map(run.usage),
      persistence: Result.persistence_status(Enum.reverse(run.persistence_errors))
    }
  end

  defp final_verdict(:empty, :success), do: :completed
  defp final_verdict(:empty, _disposition), do: :rejected_before_dispatch
  defp final_verdict(:completed, disposition) when disposition != :success, do: :unknown
  defp final_verdict(verdict, _disposition), do: verdict
end
