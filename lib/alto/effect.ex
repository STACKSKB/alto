defmodule Alto.Effect do
  @moduledoc """
  An ordered request from loop policy to the Alto runtime.

  Effects describe work; loop and hook modules do not execute external side
  effects directly. `Alto.Runner.Serial` is the first effect interpreter; other
  hosts can preserve the same loop contract while changing execution strategy.
  """

  alias Alto.Event

  @enforce_keys [:kind, :data]
  defstruct [:kind, :data]

  @type kind ::
          :emit
          | :request_model
          | :compact_context
          | :run_tool
          | :run_tools
          | :invoke_tool
          | :spawn_agents
  @type t :: %__MODULE__{kind: kind(), data: map()}

  @spec emit(Event.t()) :: t()
  def emit(%Event{} = event), do: new(:emit, %{event: event})

  @doc """
  Request a model step. Optional `:context_message` appends trusted-loop context
  as a user message before this request, under the run's transcript byte bound.
  It cannot change roles or grant tool capabilities.
  """
  @spec request_model(map()) :: t()
  def request_model(request), do: new(:request_model, request)

  @doc "Request one bounded context reduction using the configured reducer."
  def compact_context(options \\ %{}), do: new(:compact_context, options)

  @doc """
  Model-shaped tool invocation: `call` carries the provider's tool-call
  `arguments_json`. The host decodes it once. The default loop emits this
  because JSON is the shape the model produced.
  """
  @spec run_tool(map()) :: t()
  def run_tool(call), do: new(:run_tool, call)

  @doc """
  Explicit batch of model-shaped calls. Parallel, approval-free tools may run
  together; other calls are barriers. Completion hooks run after each bounded
  parallel group settles, in source order. Ordinary `run_tool` effects retain
  their interleaved hook semantics. Concurrency must be between 1 and 32.
  """
  def run_tools(calls, max_concurrency \\ 4)
      when is_list(calls) and max_concurrency in 1..32,
      do: new(:run_tools, %{calls: calls, max_concurrency: max_concurrency})

  @doc """
  Native tool invocation for loops and hooks that hold an Elixir map:
  `call` is `%{name: binary, arguments: map}` plus an optional `id` used for
  loop/event correlation. Native outcomes are added to provider history as
  explicit context, never as replies to provider tool calls. No JSON encoding
  round-trip; every downstream guarantee (preparation, approval, bounds,
  supervision) is identical to `run_tool/1`.
  """
  @spec invoke_tool(map()) :: t()
  def invoke_tool(call), do: new(:invoke_tool, call)

  @doc "Run a bounded batch of child requests and report ordered subagent outcomes."
  @spec spawn_agents(map()) :: t()
  def spawn_agents(request), do: new(:spawn_agents, request)

  defp new(kind, data) when is_map(data), do: %__MODULE__{kind: kind, data: data}
end
