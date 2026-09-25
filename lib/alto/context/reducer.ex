defmodule Alto.Context.Reducer do
  @moduledoc """
  Structured context reduction. `compact/3` receives pinned/middle/recent
  messages, historical tool schemas, limits and artifact location metadata.
  Its model function is supervised and budgeted by execution; it cannot dispatch
  tool calls. Return `%{content: binary, data: map}`. The host records one
  durable `context_compacted` event with this metadata after applying the result.
  Built-in reducers use this same contract.
  """
  @callback compact(map(), (map() -> {:ok, map()} | {:error, term()}), keyword()) ::
              {:ok, map()} | {:error, term()}

  def resolve(spec), do: Alto.Capabilities.resolve(spec, __MODULE__)

  def request(input, isolated, transcript) do
    messages =
      case input.request_mode do
        :isolated ->
          [%{"role" => "user", "content" => isolated}]

        :transcript ->
          input.pinned ++ input.middle ++ [%{"role" => "user", "content" => transcript}]
      end

    %{messages: messages, tools: input.tools, tool_choice: :none}
  end

  def render(messages) do
    Enum.map_join(messages, "\n", fn
      %{"role" => role, "content" => content} = message
      when is_binary(content) and map_size(message) == 2 ->
        role <> ": " <> content

      %{"role" => role} = message ->
        role <> ": " <> JSON.encode!(message)
    end)
  end
end
