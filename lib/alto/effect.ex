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

  @type kind :: :emit | :request_model | :run_tool | :invoke_tool | :spawn_agent
  @type t :: %__MODULE__{kind: kind(), data: map()}

  @spec emit(Event.t()) :: t()
  def emit(%Event{} = event), do: new(:emit, %{event: event})

  @spec request_model(map()) :: t()
  def request_model(request), do: new(:request_model, request)

  @doc """
  Model-shaped tool invocation: `call` carries the provider's tool-call
  `arguments_json`. The host decodes it once. The default loop emits this
  because JSON is the shape the model produced.
  """
  @spec run_tool(map()) :: t()
  def run_tool(call), do: new(:run_tool, call)

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

  @spec spawn_agent(map()) :: t()
  def spawn_agent(request), do: new(:spawn_agent, request)

  defp new(kind, data) when is_map(data), do: %__MODULE__{kind: kind, data: data}
end
