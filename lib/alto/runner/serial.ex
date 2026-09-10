defmodule Alto.Runner.Serial do
  @moduledoc """
  A bounded, sequential host for an `Alto.Loop.Spec`.

  The loop still decides *what* happens. This host only interprets effects in
  order, isolates provider/tool crashes in supervised tasks, and translates
  their results back into typed events.

  Provider, prompt, and transcript state are model capability state. A run
  without a provider is valid as long as its loop never requests a model
  effect; rule loops perform bounded tool workflows on the same host with the
  same approval, prepared-operation, bound, and cancellation guarantees.
  """

  alias Alto.Effect
  alias Alto.Effect.Outcome
  alias Alto.Event
  alias Alto.Approval.Request, as: ApprovalRequest
  alias Alto.Runner.Serial.Handle
  alias Alto.Runner.Serial.Result
  alias Alto.Runtime
  alias Alto.Session
  alias Alto.Subagents.Bounded, as: BoundedSubagents
  alias Alto.Tool.Context
  alias Alto.Transition
  alias Alto.Usage
  alias Alto.Context.Transcript
  alias Alto.Context.Window
  alias Alto.Runner.Budget

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
  @default_compaction_summary_input_bytes 100_000
  @default_retry_base_backoff_ms 500
  @default_retry_max_backoff_ms 5_000
  @subagent_await_ms 50
  @subagent_cancel_grace_ms 5_000

  @type provider_spec :: module() | {module(), keyword()}
  @type approval_spec :: module() | {module(), keyword()}
  @type run_result :: {:ok, Result.t()} | {:error, term(), Result.t()}

  @spec run(term(), keyword()) :: run_result()
  def run(task, opts \\ []) do
    case Keyword.pop(opts, :workspace_assignment) do
      {nil, opts} ->
        run_without_workspace(task, opts)

      {{manager, snapshot, identity}, opts} ->
        run_in_workspace(task, opts, manager, snapshot, identity)
    end
  end

  defp run_without_workspace(task, opts) do
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
              case Keyword.get(opts, :checkpoint) do
                nil ->
                  case call_policy(fn -> Runtime.init(run.spec, task) end, run) do
                    {:ok, transition} -> drive(transition, run, [])
                    {:cancelled, reason} -> cancelled(reason, run)
                    {:error, reason} -> {:error, reason, result(run, nil, :error)}
                  end

                {packet, decision} ->
                  resume_checkpoint(run, packet, decision, opts)

                _ ->
                  {:error, :invalid_checkpoint, result(run, nil, :error)}
              end

            persist_session_outcome(run, outcome)

          {:error, reason} ->
            {:error, reason, empty_result(session)}
        end

      {:error, reason} ->
        {:error, reason, empty_result(nil)}
    end
  end

  @doc "Start a serial run and return a handle without waiting for it.

  When `owner: pid` is supplied, Alto starts a small guardian which monitors
  that process and cooperatively cancels the run if the owner exits. The
  default has no owner guardian, preserving standalone run lifetime semantics.
  "
  @spec start(term(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def start(task, opts \\ []) do
    case validate_owner(Keyword.get(opts, :owner)) do
      :ok ->
        cancel_ref = make_ref()
        run_opts = opts |> Keyword.delete(:owner) |> Keyword.put(:cancel_ref, cancel_ref)

        case Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
               run(task, run_opts)
             end) do
          %Task{} = task_process ->
            handle = %Handle{task: task_process, cancel_ref: cancel_ref}
            maybe_start_owner_guardian(handle, Keyword.get(opts, :owner))
            {:ok, handle}
        end

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:run_start_failed, reason}}
  end

  defp validate_owner(nil), do: :ok
  defp validate_owner(owner) when is_pid(owner), do: :ok
  defp validate_owner(owner), do: {:error, {:invalid_owner, owner}}

  defp maybe_start_owner_guardian(_handle, nil), do: :ok

  defp maybe_start_owner_guardian(
         %Handle{task: %Task{pid: task_pid}, cancel_ref: cancel_ref},
         owner
       )
       when is_pid(owner) do
    spawn(fn -> owner_guardian(owner, task_pid, cancel_ref) end)
    :ok
  end

  defp owner_guardian(owner, task_pid, cancel_ref) do
    owner_ref = Process.monitor(owner)
    task_ref = Process.monitor(task_pid)

    receive do
      {:DOWN, ^task_ref, :process, ^task_pid, _reason} ->
        Process.demonitor(owner_ref, [:flush])
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, reason} ->
        if Process.alive?(task_pid),
          do: send(task_pid, {:alto_cancel, cancel_ref, {:owner_down, reason}})

        receive do
          {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
        end
    end
  end

  @doc "Wait for a previously started run without cancelling it on timeout."
  @spec await(Handle.t(), timeout()) :: run_result() | {:error, :await_timeout}
  def await(%Handle{task: task}, timeout \\ :infinity) do
    case Task.yield(task, timeout) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:run_process_failed, reason}, empty_result()}
      nil -> {:error, :await_timeout}
    end
  end

  @doc "Request cooperative cancellation of a previously started run."
  @spec cancel(Handle.t(), term()) :: :ok | :already_finished
  def cancel(%Handle{task: %Task{pid: pid}, cancel_ref: cancel_ref}, reason \\ :user) do
    if Process.alive?(pid) do
      send(pid, {:alto_cancel, cancel_ref, reason})
      :ok
    else
      :already_finished
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

  defp execute(effects, run, terminal) do
    case {cancellation(run.cancel_ref), Budget.check(run.budget)} do
      {{:cancelled, reason}, _} -> cancelled(reason, run)
      {_, {:error, reason}} -> {:error, reason, result(run, nil, :error)}
      {:continue, :ok} -> do_execute(effects, run, terminal)
    end
  end

  defp do_execute([], run, {:stop, output}), do: {:ok, result(run, output, :success)}
  defp do_execute([], run, {:error, reason}), do: {:error, reason, result(run, nil, :error)}
  defp do_execute([], run, :continue), do: {:error, :loop_stalled, result(run, nil, :error)}

  defp do_execute([effect | rest], run, terminal) do
    interpreted = with :ok <- Budget.take(run.budget), do: interpret(effect, run)

    finish_effect(interpreted, rest, run, terminal)
  end

  defp finish_effect(interpreted, rest, run, terminal) do
    case interpreted do
      {:suspend, pending, next_run} ->
        case checkpoint_call(
               fn -> Alto.Runner.Checkpoint.capture(next_run, pending, rest, terminal) end,
               next_run
             ) do
          {:ok, packet} ->
            value = %{result(next_run, nil, :checkpoint) | checkpoint: packet}
            {:error, :approval_suspended, value}

          {:error, reason} ->
            {:error, reason, result(next_run, nil, :error)}
        end

      {:error, reason} ->
        {:error, reason, result(run, nil, :error)}

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
          {:cancelled, reason} -> cancelled(reason, next_run)
          {:error, reason} -> {:error, reason, result(next_run, nil, :error)}
        end

      {:error, {:cancelled, reason}, next_run} ->
        cancelled(reason, next_run)

      {:error, reason, next_run} ->
        {:error, reason, result(next_run, nil, :error)}

      {:cancelled, reason, next_run} ->
        cancelled(reason, next_run)
    end
  end

  defp resume_checkpoint(run, packet, decision, opts) do
    with {:ok, restored, frame} <-
           checkpoint_call(
             fn -> Alto.Runner.Checkpoint.restore(run, packet, decision, opts) end,
             run
           ),
         :ok <- Budget.check(restored.budget),
         {:ok, tool} <- fetch_tool(restored.tools, frame.pending.request.tool) do
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
      {:error, reason} -> {:error, reason, result(run, nil, :error)}
    end
  end

  defp checkpoint_call(fun, run) do
    case supervised_call(fun, Budget.timeout(run.budget, 30_000), run.cancel_ref) do
      {:ok, value} -> value
      {:error, reason} -> {:error, {:checkpoint_process_failed, reason}}
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
    end
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
         {:ok, specs} <- prepare_subagent_workspaces(specs, run) do
      {status, outcomes} =
        Alto.Runner.SubagentBatch.run(specs, concurrency, &start_subagent(&1, run), fn ->
          case {cancellation(run.cancel_ref), Budget.check(run.budget)} do
            {{:cancelled, _} = cancelled, _} -> cancelled
            {_, {:error, _} = error} -> error
            _ -> :continue
          end
        end)

      {results, run} =
        Enum.map_reduce(outcomes, run, fn {id, outcome}, acc ->
          {subagent_data(id, outcome), merge_child_result(acc, outcome)}
        end)

      case status do
        :ok -> batch_completed(results, run)
        {:cancelled, reason} -> {:cancelled, reason, run}
        {:error, reason} -> {:error, reason, run}
      end
    else
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

  defp check_context(
         request,
         %{spec: %{context: %Window{} = policy}, provider: {provider, opts}} = run
       ) do
    checked =
      supervised_call(
        fn -> Window.check(policy, request, provider.describe(opts)) end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case checked do
      {:ok, {:ok, budget}} -> reserve_output(request, budget)
      {:ok, {:error, reason}} -> {:error, reason}
      {:cancelled, reason} -> {:error, {:cancelled, reason}}
      {:error, reason} -> {:error, {:context_policy_failed, reason}}
    end
  end

  defp check_context(request, _run), do: {:ok, request}

  defp reserve_output(request, budget) when is_map(budget) and budget.reserve_output > 0 do
    requested = Map.get(request.options, "max_tokens", budget.reserve_output)

    if is_integer(requested) and requested > 0 do
      {:ok,
       %{
         request
         | options: Map.put(request.options, "max_tokens", min(requested, budget.reserve_output))
       }}
    else
      {:error, :invalid_max_tokens}
    end
  end

  defp reserve_output(request, _budget), do: {:ok, request}

  # Bounded, visible retry for model transport only. Tool effects are never
  # retried: repeating a side effect is a policy decision, not a transport
  # concern. Our own deadline (`:timeout`) is never retried either — retrying
  # it would make the configured bound meaningless. Every retry emits a live
  # event carrying the attempt number and failure class, never response
  # bodies; `model_requests` still counts one step per disposition.
  defp stream_with_retries(provider, request, sink, provider_opts, run, step) do
    attempt_stream(provider, request, sink, provider_opts, run, step, 1, run.provider_retries + 1)
  end

  defp attempt_stream(provider, request, sink, provider_opts, run, step, attempt, max_attempts) do
    case cancellation(run.cancel_ref) do
      {:cancelled, reason} ->
        {:cancelled, reason}

      :continue ->
        outcome =
          supervised_call(
            fn ->
              with :ok <- Budget.take_model(run.budget),
                   do: provider.stream(request, sink, provider_opts)
            end,
            Budget.timeout(run.budget, run.provider_timeout),
            run.cancel_ref
          )

        maybe_retry_stream(
          outcome,
          provider,
          request,
          sink,
          provider_opts,
          run,
          step,
          attempt,
          max_attempts
        )
    end
  end

  defp maybe_retry_stream(
         {:ok, {:error, reason}} = outcome,
         provider,
         request,
         sink,
         provider_opts,
         run,
         step,
         attempt,
         max_attempts
       ) do
    if attempt < max_attempts and retryable_stream_error?(reason) do
      notify(
        run.event_sink,
        Event.live(:model_retry, %{
          step: step,
          attempt: attempt,
          max_attempts: max_attempts,
          kind: stream_error_kind(reason)
        })
      )

      case sleep_backoff(attempt, run.cancel_ref, run.budget) do
        :ok ->
          attempt_stream(
            provider,
            request,
            sink,
            provider_opts,
            run,
            step,
            attempt + 1,
            max_attempts
          )

        {:cancelled, reason} ->
          {:cancelled, reason}
      end
    else
      outcome
    end
  end

  defp maybe_retry_stream(
         outcome,
         _provider,
         _request,
         _sink,
         _opts,
         _run,
         _step,
         _attempt,
         _max
       ),
       do: outcome

  defp retryable_stream_error?({:transport_error, _reason}), do: true
  defp retryable_stream_error?({:http_error, 429, _detail}), do: true
  defp retryable_stream_error?({:http_error, status, _detail}) when status >= 500, do: true
  defp retryable_stream_error?(_reason), do: false

  defp stream_error_kind({:transport_error, _reason}), do: :transport
  defp stream_error_kind({:http_error, status, _detail}), do: {:http, status}

  defp sleep_backoff(attempt, cancel_ref, budget) do
    backoff =
      min(
        @default_retry_base_backoff_ms * Integer.pow(2, attempt - 1),
        @default_retry_max_backoff_ms
      )

    sleep_until(System.monotonic_time(:millisecond) + Budget.timeout(budget, backoff), cancel_ref)
  end

  defp sleep_until(deadline, cancel_ref) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(50)

      case cancellation(cancel_ref) do
        {:cancelled, reason} -> {:cancelled, reason}
        :continue -> sleep_until(deadline, cancel_ref)
      end
    end
  end

  # Owned serial sub-runs. The loop decides when to delegate; the host owns
  # the mechanics: depth budget from the loop spec's subagent policy (absent
  # or zero means delegation is disabled), inherited provider/tools/approval
  # with no widening, progress forwarded as live events, a validated result
  # shape back to the loop, and cancellation that tears the child down.

  defp validate_spawn(data) when is_map(data) do
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

  defp validate_spawn(data), do: {:error, {:not_a_map, data}}

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

  defp run_subagent(spec, run) do
    with {:ok, [prepared]} <- prepare_subagent_workspaces([spec], run),
         {:ok, handle} <- start_subagent(prepared, run) do
      await_subagent(handle, spec, run)
    else
      {:error, reason} -> {:event, subagent_failed(spec.id, reason), run}
    end
  end

  defp configured_workspaces(%BoundedSubagents{workspaces: manager}), do: manager
  defp configured_workspaces(_), do: nil

  defp prepare_subagent_workspaces(specs, %{workspaces: nil}), do: {:ok, specs}

  defp prepare_subagent_workspaces(specs, run) do
    with {:ok, snapshot} <-
           workspace_call(
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
  defp run_in_workspace(task, opts, manager, snapshot, identity) do
    budget = Keyword.fetch!(opts, :budget)
    timeout = Keyword.get(opts, :tool_timeout, @default_tool_timeout)
    cancel_ref = Keyword.get(opts, :cancel_ref)

    with {:ok, ready} <-
           workspace_call(
             fn -> Alto.Workspaces.create(manager, snapshot, identity) end,
             budget,
             timeout,
             cancel_ref
           ),
         {:ok, outcome, worked} <-
           Alto.Workspaces.use(manager, ready.id, ready.revision, fn workspace ->
             run_without_workspace(task, Keyword.put(opts, :cwd, workspace["cwd"]))
           end) do
      case workspace_call(
             fn -> Alto.Workspaces.freeze(manager, worked.id, worked.revision) end,
             budget,
             timeout,
             cancel_ref
           ) do
        {:ok, frozen} ->
          attach_workspace(outcome, frozen)

        {:error, reason} ->
          info =
            case Alto.Workspaces.get(manager, worked.id) do
              {:ok, current} -> current
              _ -> worked
            end

          workspace_failure(outcome, info, reason)
      end
    else
      {:error, reason, outcome} ->
        workspace_failure(outcome, nil, reason)

      {:error, reason} ->
        {:error, {:workspace_failed, reason},
         %{empty_result() | verdict: :unknown, agent_identity: identity}}
    end
  end

  defp workspace_call(fun, budget, timeout, cancel_ref) do
    case Budget.check(budget) do
      :ok ->
        case supervised_call(fun, Budget.timeout(budget, timeout), cancel_ref) do
          {:ok, value} -> value
          {:error, reason} -> {:error, {:workspace_process_failed, reason}}
          {:cancelled, reason} -> {:error, {:cancelled, reason}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp attach_workspace({:ok, result}, info), do: {:ok, %{result | workspace: info}}

  defp attach_workspace({:error, reason, result}, info),
    do: {:error, reason, %{result | workspace: info}}

  defp workspace_failure(outcome, info, reason) do
    result = elem(outcome, tuple_size(outcome) - 1)
    {:error, {:workspace_failed, reason}, %{result | verdict: :unknown, workspace: info}}
  end

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
          tools: subagent_tools(spec.tools, run),
          approval: run.approval,
          loop: spec.loop || Alto.default_loop()
        ] ++
          prompt_opts ++
          [
            cwd: run.tool_context.cwd,
            workspace_assignment: Map.get(spec, :workspace_assignment),
            parent_workspaces: run.workspaces,
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

      start(spec.task, sub_opts)
    end
  end

  defp child_session_options(%{session: nil}), do: [session: nil, resume_snapshot: false]

  defp child_session_options(%{spec: %{subagents: %BoundedSubagents{sessions: :separate}}} = run),
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

  defp await_subagent(handle, spec, run) do
    case await(handle, @subagent_await_ms) do
      {:error, :await_timeout} ->
        case cancellation(run.cancel_ref) do
          {:cancelled, reason} ->
            cancel(handle, reason)
            outcome = shutdown_subagent(handle)
            {:cancelled, reason, merge_child_result(run, outcome)}

          :continue ->
            await_subagent(handle, spec, run)
        end

      outcome ->
        data = subagent_data(spec.id, outcome)
        type = if data.status == :error, do: :subagent_failed, else: :subagent_completed
        {:event, Event.durable(type, data), merge_child_result(run, outcome)}
    end
  end

  defp shutdown_subagent(handle) do
    case await(handle, @subagent_cancel_grace_ms) do
      {:error, :await_timeout} ->
        case Task.shutdown(handle.task, :brutal_kill) do
          {:ok, outcome} -> outcome
          _ -> {:error, {:run_process_failed, :cancel_timeout}}
        end

      outcome ->
        outcome
    end
  end

  defp subagent_data(id, {:ok, result}),
    do: Map.merge(child_fields(id, result), %{status: :ok})

  defp subagent_data(id, {:error, {:cancelled, reason}, result}),
    do: Map.merge(child_fields(id, result), %{status: :cancelled, reason: reason})

  defp subagent_data(id, {:error, reason, result}),
    do: Map.merge(child_fields(id, result), %{status: :error, error: reason})

  defp subagent_data(id, {:error, reason}), do: %{id: id, status: :error, error: reason}

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

  defp merge_child_result(run, {:error, {:run_process_failed, _}, _}),
    do: merge_verdict(run, :unknown)

  defp merge_child_result(run, {:error, {:run_process_failed, _}}),
    do: merge_verdict(run, :unknown)

  defp merge_child_result(run, {:error, _reason, result}),
    do: merge_child_result(run, {:ok, result})

  defp merge_child_result(run, {:ok, result}) do
    run = merge_verdict(run, result.verdict)
    run = %{run | usage: Usage.merge(run.usage, struct(Usage, result.usage))}

    Enum.reduce(
      existing_persistence_errors(result),
      run,
      &add_persistence_error(&2, {:subagent, &1})
    )
  end

  defp merge_child_result(run, _outcome), do: run

  defp batch_completed(results, run) do
    data = %{results: results}

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

  defp validate_subagent_tools(:inherit, _run), do: :ok

  defp validate_subagent_tools(tools, run) do
    inherited = Enum.map(run.tool_specs, &canonical_tool/1)

    if Enum.all?(tools, &(canonical_tool(&1) in inherited)),
      do: :ok,
      else: {:error, :tool_scope_exceeded}
  end

  defp canonical_tool(module) when is_atom(module), do: {module, []}
  defp canonical_tool(spec), do: spec

  defp validate_batch(%{agents: agents}, run) when is_list(agents) do
    case run.spec.subagents do
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

  defp validate_batch(_data, _run), do: {:error, :invalid_agents}

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

  defp subagent_failed(id, reason) do
    Event.durable(:subagent_failed, %{id: id, error: reason})
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

  defp prepare_tool(%{preparation: :none}, arguments, _run), do: {:ok, arguments, %{}}

  defp prepare_tool(tool, arguments, run) do
    outcome =
      supervised_call(
        fn -> invoke_prepare(tool, arguments, run.tool_context) end,
        Budget.timeout(run.budget, run.tool_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, prepared, details}} when is_map(details) ->
        bound_approval_details(prepared, details, run.max_approval_details_bytes)

      {:ok, {:ok, _prepared, details}} ->
        {:error, {:invalid_approval_details, details}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_tool_prepare_return, other}}

      {:error, reason} ->
        {:error, {:tool_prepare_process_failed, reason}}

      {:cancelled, reason} ->
        {:cancelled, reason}
    end
  end

  defp bound_approval_details(prepared, details, limit) do
    if :erlang.external_size(details) <= limit do
      {:ok, prepared, details}
    else
      {:error, {:approval_details_limit, limit}}
    end
  end

  defp invoke_prepare(%{module: module, preparation: :arity2}, arguments, context) do
    module.prepare(arguments, context)
  end

  defp invoke_prepare(%{module: module, opts: opts, preparation: :arity3}, arguments, context) do
    module.prepare(arguments, context, opts)
  end

  defp authorize_tool(_call_id, _name, _arguments, _details, %{approval: :never}, _run, _op_id),
    do: :ok

  # The approval handle is the operation id: globally unambiguous,
  # while `call_id` is preserved for transcript/loop correlation. The exact
  # opaque `prepared` value authorized here is the value `run_tool/7`
  # executes — no second preparation.
  defp authorize_tool(call_id, name, arguments, details, tool, run, op_id) do
    request = %ApprovalRequest{
      id: op_id,
      run_id: run.tool_context.session_id,
      call_id: call_id,
      operation_id: op_id,
      tool: name,
      arguments: arguments,
      execution_mode: tool.execution_mode,
      details: details
    }

    notify(run.event_sink, Event.live(:approval_requested, %{request: request}))
    {policy, policy_opts} = run.approval

    outcome =
      supervised_call(
        fn -> policy.decide(request, run.tool_context, policy_opts) end,
        Budget.timeout(run.budget, run.approval_timeout),
        run.cancel_ref
      )

    decision =
      case outcome do
        {:ok, :approve} -> :ok
        {:ok, :suspend} -> {:suspend, request}
        {:ok, {:deny, reason}} -> {:deny, reason}
        {:ok, other} -> {:error, {:invalid_decision, other}}
        {:error, reason} -> {:error, {:policy_process_failed, reason}}
        {:cancelled, reason} -> {:cancelled, reason}
      end

    notify(
      run.event_sink,
      Event.live(:approval_resolved, %{
        request: request,
        decision: approval_event_decision(decision)
      })
    )

    decision
  end

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

        case supervised_call(
               fn -> invoke_tool(tool, prepared, run.tool_context) end,
               Budget.timeout(run.budget, run.tool_timeout),
               run.cancel_ref
             ) do
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

  defp invoke_tool(%{module: module, preparation: :arity2}, prepared, context) do
    module.run_prepared(prepared, context)
  end

  defp invoke_tool(
         %{module: module, opts: opts, preparation: :arity3},
         prepared,
         context
       ) do
    module.run_prepared(prepared, context, opts)
  end

  defp invoke_tool(%{module: module, opts: []}, arguments, context) do
    module.run(arguments, context)
  end

  defp invoke_tool(%{module: module, opts: opts}, arguments, context) do
    module.run(arguments, context, opts)
  end

  defp approval_event_decision({:suspend, _request}), do: :suspended
  defp approval_event_decision(:ok), do: :approved
  defp approval_event_decision({:deny, reason}), do: {:denied, reason}
  defp approval_event_decision({:error, reason}), do: {:error, reason}
  defp approval_event_decision({:cancelled, reason}), do: {:cancelled, reason}

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
    bytes = run.transcript_bytes + byte_size(JSON.encode!(message))

    if bytes <= run.max_transcript_bytes do
      {:ok, %{run | messages_rev: [message | run.messages_rev], transcript_bytes: bytes}}
    else
      compact_transcript(run, message)
    end
  end

  # One bounded recovery rollover per run when the transcript ceiling hits.
  # The compatibility strategy summarizes the middle. The coding-harness
  # strategy produces a structured, persisted handoff. Both keep the system
  # message and a recent region verbatim, and both require a session so the
  # removed semantic facts remain durable. Any failure degrades to the
  # pre-rollover transcript error, never a retry loop.
  defp compact_transcript(%{compaction: false} = run, _message),
    do: {:error, {:transcript_limit, run.max_transcript_bytes}, run}

  defp compact_transcript(%{compacted?: true} = run, _message),
    do: {:error, {:transcript_limit, run.max_transcript_bytes}, run}

  defp compact_transcript(%{session: nil} = run, _message),
    do: {:error, :compaction_requires_session, run}

  defp compact_transcript(%{provider: nil} = run, _message),
    do: {:error, :compaction_requires_provider, run}

  defp compact_transcript(run, message) do
    case compact_middle(run) do
      {:ok, run} ->
        append_message(%{run | compacted?: true}, message)

      {:error, {:cancelled, _} = reason, run} ->
        {:error, reason, run}

      {:error, _reason, run} ->
        {:error, {:transcript_limit, run.max_transcript_bytes}, run}
    end
  end

  defp compact_middle(%{model_requests: count, max_steps: limit} = run) when count >= limit,
    do: {:error, {:model_step_limit, limit}, run}

  defp compact_middle(run) do
    case Keyword.fetch!(run.compaction, :strategy) do
      :summary -> summarize_middle(run)
      :handoff -> handoff_middle(run)
      {module, opts} -> custom_compaction(run, module, opts)
    end
  end

  defp custom_compaction(run, module, opts) do
    {system, middle, recent} =
      Transcript.split(
        Enum.reverse(run.messages_rev),
        Keyword.fetch!(run.compaction, :keep_recent_messages)
      )

    limit = Keyword.fetch!(run.compaction, :max_summary_bytes)
    input = render_for_summary(middle)
    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    outcome =
      supervised_call(
        fn ->
          with false <- middle == [],
               {:ok, request} <- module.request(input, limit, opts),
               true <-
                 is_map(request) and is_list(request[:messages]) and request[:tools] in [nil, []],
               :ok <- Budget.take_model(run.budget),
               {:ok, completion} <-
                 provider.stream(Map.put(request, :tools, []), sink, provider_opts),
               {:ok, content} <- module.decode(completion, limit, opts),
               true <-
                 is_binary(content) and content != "" and byte_size(content) <= limit and
                   String.valid?(content) do
            {:ok, content}
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_compaction_result}
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, content}} ->
        apply_summary(
          run,
          system,
          middle,
          transcript_part_bytes(middle),
          byte_size(input),
          recent,
          content,
          limit
        )

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      other ->
        record_compact_failed(run, {:custom_compaction_failed, other})
    end
  end

  defp summarize_middle(run) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_summary = Keyword.fetch!(run.compaction, :max_summary_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      summarize_replacement(run, system, middle, recent, max_summary)
    end
  end

  defp handoff_middle(run) do
    keep = Keyword.fetch!(run.compaction, :keep_recent_messages)
    max_handoff = Keyword.fetch!(run.compaction, :max_handoff_bytes)
    messages = Enum.reverse(run.messages_rev)

    {system, middle, recent} = Transcript.split(messages, keep)

    if middle == [] do
      {:error, :transcript_uncompactable, run}
    else
      generate_handoff(run, system, middle, recent, max_handoff)
    end
  end

  defp generate_handoff(run, system, middle, recent, max_handoff) do
    middle_bytes = transcript_part_bytes(middle)
    input = render_for_summary(middle)
    input_bytes = byte_size(input)
    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    notify(
      run.event_sink,
      Event.live(:context_handoff_started, %{dropped_messages: length(middle)})
    )

    outcome =
      supervised_call(
        fn ->
          with :ok <- Budget.take_model(run.budget) do
            provider.stream(
              %{
                messages: [
                  %{"role" => "user", "content" => Alto.Handoff.prompt(input, max_handoff)}
                ],
                tools: []
              },
              sink,
              provider_opts
            )
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, %{message: message} = completion}} when is_binary(message) ->
        run = %{run | usage: Usage.merge(run.usage, Usage.normalize(Map.get(completion, :usage)))}

        with {:ok, artifact} <- Alto.Handoff.decode(message, max_handoff),
             {:ok, published} <-
               Alto.Handoff.persist(
                 run.session,
                 run.tool_context.session_id,
                 artifact,
                 handoff_persist_opts(run)
               ) do
          apply_handoff(
            run,
            system,
            middle,
            middle_bytes,
            input_bytes,
            recent,
            artifact,
            published
          )
        else
          {:error, reason} -> record_compact_failed(run, reason)
        end

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      {:ok, _other} ->
        record_compact_failed(run, :handoff_response_empty)

      {:error, reason} ->
        record_compact_failed(run, {:handoff_failed, reason})
    end
  end

  defp apply_handoff(
         run,
         system,
         middle,
         middle_bytes,
         input_bytes,
         recent,
         artifact,
         published
       ) do
    rendered = Alto.Handoff.render(artifact)

    header = "[alto handoff: artifacts at #{published.directory}]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n\n" <> rendered}] ++ recent

    bytes = transcript_part_bytes(replacement)

    run = %{
      run
      | messages_rev: Enum.reverse(replacement),
        transcript_bytes: bytes,
        model_requests: run.model_requests + 1
    }

    data = %{
      strategy: :handoff,
      dropped_messages: length(middle),
      dropped_bytes: middle_bytes,
      source_bytes: input_bytes,
      handoff_bytes: byte_size(rendered),
      kept_messages: length(recent),
      directory: published.directory,
      files: published.files,
      next_step: artifact.next_step
    }

    run = record_event(run, Event.durable(:context_handoff_created, data))
    run = record_event(run, Event.durable(:context_compacted, data))

    run =
      case Session.append(
             run.session,
             Session.handoff_record(Map.put(data, :run_id, run.tool_context.session_id)),
             session_dir_opt(run)
           ) do
        :ok -> run
        {:error, reason} -> add_persistence_error(run, reason)
      end

    {:ok, run}
  end

  defp handoff_persist_opts(run) do
    base = session_dir_opt(run)

    case Keyword.fetch!(run.compaction, :artifact_dir) do
      nil -> base
      directory -> Keyword.put(base, :artifact_dir, directory)
    end
  end

  defp summarize_replacement(run, system, middle, recent, max_summary) do
    middle_bytes = transcript_part_bytes(middle)
    input = render_for_summary(middle)
    summarizable_bytes = byte_size(input)

    prompt =
      "Summarize this agent work transcript so the run can continue without it. " <>
        "Preserve: the active task and any plan, key decisions taken, files read or modified, " <>
        "tool outcomes the next steps depend on, errors and how they were handled, and anything " <>
        "explicitly marked unresolved. Omit pleasantries and repetition. " <>
        "Reply with plain text under #{max_summary} bytes, no tool calls."

    {provider, provider_opts} = run.provider
    sink = fn event -> notify(run.event_sink, event) end

    notify(run.event_sink, Event.live(:context_compacting, %{dropped_messages: length(middle)}))

    outcome =
      supervised_call(
        fn ->
          with :ok <- Budget.take_model(run.budget) do
            provider.stream(
              %{
                messages: [
                  %{"role" => "user", "content" => prompt <> "\n\nTranscript:\n" <> input}
                ],
                tools: []
              },
              sink,
              provider_opts
            )
          end
        end,
        Budget.timeout(run.budget, run.provider_timeout),
        run.cancel_ref
      )

    case outcome do
      {:ok, {:ok, %{message: message} = completion}} when is_binary(message) and message != "" ->
        run = %{run | usage: Usage.merge(run.usage, Usage.normalize(Map.get(completion, :usage)))}

        apply_summary(
          run,
          system,
          middle,
          middle_bytes,
          summarizable_bytes,
          recent,
          message,
          max_summary
        )

      {:cancelled, reason} ->
        {:error, {:cancelled, reason}, run}

      {:ok, _other} ->
        record_compact_failed(run, :compaction_summary_empty)

      {:error, reason} ->
        record_compact_failed(run, {:compaction_failed, reason})
    end
  end

  defp apply_summary(
         run,
         system,
         middle,
         middle_bytes,
         summarizable_bytes,
         recent,
         message,
         max_summary
       ) do
    summary = message |> binary_part(0, min(byte_size(message), max_summary)) |> trim_utf8_tail()

    header =
      "[alto compaction: summarized #{length(middle)} messages; full history in session log]"

    replacement =
      system ++ [%{"role" => "user", "content" => header <> "\n" <> summary}] ++ recent

    bytes = transcript_part_bytes(replacement)

    run = %{
      run
      | messages_rev: Enum.reverse(replacement),
        transcript_bytes: bytes,
        model_requests: run.model_requests + 1
    }

    run =
      record_event(
        run,
        Event.durable(:context_compacted, %{
          dropped_messages: length(middle),
          dropped_bytes: middle_bytes,
          summarized_bytes: summarizable_bytes,
          summary_bytes: byte_size(summary),
          kept_messages: length(recent)
        })
      )

    persisted =
      if run.session do
        Session.append(
          run.session,
          Session.compaction_record(%{
            run_id: run.tool_context.session_id,
            dropped_messages: length(middle),
            dropped_bytes: middle_bytes,
            summary_bytes: byte_size(summary),
            summary: summary
          }),
          session_dir_opt(run)
        )
      end

    run =
      case persisted do
        {:error, reason} -> add_persistence_error(run, reason)
        _ -> run
      end

    {:ok, run}
  end

  defp trim_utf8_tail(text) do
    if String.valid?(text),
      do: text,
      else: trim_utf8_tail(binary_part(text, 0, byte_size(text) - 1))
  end

  defp record_compact_failed(run, reason) do
    run = record_event(run, Event.durable(:context_compact_failed, %{error: reason}))
    {:error, reason, run}
  end

  defp transcript_part_bytes(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + byte_size(JSON.encode!(message)) end)
  end

  # The summarizer sees the most recent slice of the dropped middle,
  # capped in bytes and cut on a UTF-8 boundary so the prompt stays valid.
  defp render_for_summary(messages) do
    rendered =
      messages
      |> Enum.map(fn
        %{"role" => role, "content" => content} when is_binary(content) -> role <> ": " <> content
        %{"role" => role} = message -> role <> ": " <> JSON.encode!(message)
      end)
      |> Enum.join("\n")

    take_trailing_bytes(rendered, @default_compaction_summary_input_bytes)
  end

  defp take_trailing_bytes(rendered, max) do
    drop_to_valid(rendered, max(byte_size(rendered) - max, 0))
  end

  defp drop_to_valid(rendered, start) do
    tail = binary_part(rendered, start, byte_size(rendered) - start)

    if String.valid?(tail) do
      tail
    else
      drop_to_valid(rendered, start + 1)
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

  defp fetch_tool(tools, name) when is_binary(name) do
    case Map.fetch(tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  defp fetch_tool(_tools, name), do: {:error, {:invalid_tool_name, name}}

  defp supervised_call(fun, timeout, cancel_ref) do
    task = Task.Supervisor.async_nolink(Alto.TaskSupervisor, fun)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_supervised(task, deadline, cancel_ref)
  end

  defp await_supervised(task, deadline, cancel_ref) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    interval = min(remaining, 50)

    case Task.yield(task, interval) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:error, reason}

      nil when remaining == 0 ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}

      nil ->
        case cancellation(cancel_ref) do
          {:cancelled, reason} ->
            Task.shutdown(task, :brutal_kill)
            {:cancelled, reason}

          :continue ->
            await_supervised(task, deadline, cancel_ref)
        end
    end
  end

  defp cancellation(nil), do: :continue

  defp cancellation(cancel_ref) do
    receive do
      {:alto_cancel, ^cancel_ref, reason} -> {:cancelled, reason}
    after
      0 -> :continue
    end
  end

  # : a cancellation that lands while an operation is dispatched preserves
  # uncertainty. `in_flight` is nil when nothing was dispatched (approval,
  # preparation, provider wait), and carries the operation with an `:unknown`
  # outcome once the prepared value may have committed. Consumers must
  # reconcile or park such operations, never assume either way.
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

  defp record_event(run, %Event{domain: :durable} = event) do
    run =
      case persist_event(run, event) do
        :ok -> run
        {:error, reason} -> add_persistence_error(run, reason)
      end

    do_record_event(run, event)
  end

  defp record_event(run, event), do: do_record_event(run, event)

  # Live signals stay in flight only; the durable log is what sessions keep.
  # Event persistence is best-effort and silent on the hot path — rare paths
  # (started/transcript/completed) warn instead.
  defp persist_event(%{session: nil}, _event), do: :ok

  defp persist_event(run, event) do
    Session.append(
      run.session,
      Session.event_record(run.tool_context.session_id, event),
      session_dir_opt(run)
    )
  end

  defp do_record_event(run, %Event{} = event) do
    notify(run.event_sink, event)

    run = merge_event_verdict(run, event)

    events_rev = [event | run.events_rev]

    if length(events_rev) > run.max_events do
      %{
        run
        | events_rev: List.delete_at(events_rev, -1),
          events_dropped: run.events_dropped + 1
      }
    else
      %{run | events_rev: events_rev}
    end
  end

  defp persist_session_outcome(%{session: nil}, outcome),
    do: put_persistence(outcome, :not_requested)

  defp persist_session_outcome(run, {:ok, result}) do
    errors =
      existing_persistence_errors(result) ++
        persistence_errors([
          persist_transcript(run, result),
          persist_completed(run, "ok", nil, result)
        ])

    put_persistence({:ok, result}, persistence_status(errors))
  end

  defp persist_session_outcome(run, {:error, :approval_suspended, result}) do
    # A paused run has no completed transcript. Its exact continuation is
    # persisted by the host ledger before acknowledging its claim.
    errors =
      existing_persistence_errors(result) ++
        persistence_errors([persist_completed(run, "suspended", nil, result)])

    put_persistence({:error, :approval_suspended, result}, persistence_status(errors))
  end

  defp persist_session_outcome(run, {:error, reason, result}) do
    completion =
      case reason do
        {:cancelled, cause} -> persist_completed(run, "cancelled", cause, result)
        _other -> persist_completed(run, "error", reason, result)
      end

    errors =
      existing_persistence_errors(result) ++
        persistence_errors([persist_transcript(run, result), completion])

    put_persistence({:error, reason, result}, persistence_status(errors))
  end

  defp existing_persistence_errors(%{persistence: {:degraded, errors}}), do: errors
  defp existing_persistence_errors(_result), do: []

  defp persistence_errors(results) do
    Enum.flat_map(results, fn
      :ok -> []
      {:error, reason} -> [reason]
    end)
  end

  defp persistence_status([]), do: :ok
  defp persistence_status(errors), do: {:degraded, errors}

  defp put_persistence({:ok, result}, status), do: {:ok, %{result | persistence: status}}

  defp put_persistence({:error, reason, result}, status),
    do: {:error, reason, %{result | persistence: status}}

  # Shared-session children cannot write the parent's sidecar. A child with
  # a separate session owns its own snapshot and revision stream.
  defp persist_transcript(%{resume_snapshot: false}, _result), do: :ok
  defp persist_transcript(%{checkpoint_resume: true}, %{loop_state: nil}), do: :ok

  defp persist_transcript(run, result) do
    case Session.write_transcript(
           run.session,
           result.messages,
           result.transcript_bytes,
           Keyword.put(
             session_dir_opt(run),
             :expected_revision,
             run.transcript_revision
           )
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto: session transcript not persisted: #{inspect(reason, limit: 5)}")
        {:error, reason}
    end
  end

  defp persist_completed(run, outcome, reason, result) do
    record =
      Session.completed_record(%{
        run_id: run.tool_context.session_id,
        subagent: run.agent_depth > 0,
        session_owner: run.agent_depth == 0 or run.resume_snapshot,
        outcome: outcome,
        reason: reason,
        output: result.output,
        model_requests: result.model_requests
      })

    case Session.append(run.session, record, session_dir_opt(run)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("alto: session completion not persisted: #{inspect(reason, limit: 5)}")
        {:error, reason}
    end
  end

  defp session_dir_opt(run), do: [session_dir: run.session_dir]

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

  defp provider_identity(nil), do: {nil, nil}

  defp provider_identity({module, opts}) when is_atom(module) and is_list(opts) do
    {Atom.to_string(module), Keyword.get(opts, :model)}
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
      checkpoint_version: Keyword.get(opts, :checkpoint_version),
      checkpoint_resume: not is_nil(Keyword.get(opts, :checkpoint)),
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
          configured_workspaces(settings.spec.subagents),
      resume_snapshot: true,
      tool_specs: [],
      prompt_config: []
    }

    with {:ok, _} <- normalize_agent_identity(agent_identity),
         do: {:ok, Map.merge(initial, settings)}
  end

  # A provider is model capability state: generic rule runs are constructed
  # without one and fail closed only if a model effect is requested.
  defp normalize_provider(nil, _opts), do: {:ok, nil}

  defp normalize_provider({module, opts}, _fallback) when is_atom(module) and is_list(opts),
    do: provider_contract(module, opts)

  defp normalize_provider(module, opts) when is_atom(module) and is_list(opts),
    do: provider_contract(module, opts)

  defp normalize_provider(other, _opts), do: {:error, {:invalid_provider, other}}

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

  defp stringify_top_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
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

  defp child_agent_identity(%{root_run_id: root_run_id, path: path}, id),
    do: %{root_run_id: root_run_id, path: path ++ [id]}

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

  defp task_text(task) when is_binary(task), do: task
  defp task_text(task), do: inspect(task)

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

  defp empty_result(session_id \\ nil) do
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

  defp merge_event_verdict(run, %{type: type, data: data})
       when type in [:tool_completed, :tool_failed] do
    merge_verdict(run, Map.get(data, :outcome, :empty))
  end

  defp merge_event_verdict(run, %{type: :run_cancelled, data: %{in_flight: in_flight}})
       when not is_nil(in_flight),
       do: merge_verdict(run, :unknown)

  defp merge_event_verdict(run, _event), do: run

  defp add_persistence_error(run, reason) do
    Map.update(run, :persistence_errors, [reason], &[reason | &1])
  end

  defp merge_verdict(run, class) do
    Map.put(run, :verdict, worse_verdict(Map.get(run, :verdict, :empty), class))
  end

  defp worse_verdict(left, right) do
    severity = %{
      empty: 0,
      completed: 1,
      rejected_before_dispatch: 2,
      failed_known: 3,
      unknown: 4
    }

    if Map.get(severity, right, 0) > Map.get(severity, left, 0), do: right, else: left
  end

  defp final_verdict(:empty, :success), do: :completed
  defp final_verdict(:empty, _disposition), do: :rejected_before_dispatch
  defp final_verdict(:completed, disposition) when disposition != :success, do: :unknown
  defp final_verdict(verdict, _disposition), do: verdict
end
