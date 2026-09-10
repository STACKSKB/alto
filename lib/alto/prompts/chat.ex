defmodule Alto.Prompts.Chat do
  @moduledoc "A small conversational system-prompt builder."

  @behaviour Alto.Prompt.Builder

  @identity "You are a conversational assistant running in the Alto harness."
  @no_tools "Answer directly; no external tools are available."
  @with_tools "Use an available tool only when it materially improves the answer."
  @finish "Give a clear, self-contained response to the user."

  @impl true
  def build(%{tools: tools}, opts) do
    identity = Keyword.get(opts, :identity, @identity)
    [identity, tools_fragment(tools), @finish] |> Alto.Prompt.render()
  end

  defp tools_fragment([]), do: @no_tools
  defp tools_fragment(_tools), do: @with_tools
end
