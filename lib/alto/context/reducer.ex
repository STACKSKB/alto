defmodule Alto.Context.Reducer do
  @moduledoc """
  Structured context reduction. `compact/3` receives pinned/middle/recent
  messages, historical tool schemas, limits and artifact location metadata.
  Its model function is supervised and budgeted by execution; it cannot dispatch
  tool calls. Return replacement content, event metadata and session records.
  Built-in reducers use this same contract.
  """
  @callback compact(map(), (map() -> {:ok, map()} | {:error, term()}), keyword()) ::
              {:ok, map()} | {:error, term()}

  def resolve(:summary), do: {:ok, {Alto.Context.Reducers.Summary, []}}
  def resolve(:handoff), do: {:ok, {Alto.Context.Reducers.Handoff, []}}

  def resolve({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
         function_exported?(module, :compact, 3) do
      {:ok, {module, opts}}
    else
      {:error, {:invalid_strategy, module}}
    end
  end

  def resolve(other), do: {:error, {:invalid_strategy, other}}

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
