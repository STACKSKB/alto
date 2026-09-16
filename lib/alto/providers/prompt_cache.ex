defmodule Alto.Providers.PromptCache do
  @moduledoc "Provider-specific cache hints without modifying conversation content."

  def anthropic(body, false), do: body

  def anthropic(body, control) when is_map(control),
    do: Map.put_new(body, "cache_control", control)

  def anthropic(body, _), do: Map.put_new(body, "cache_control", %{"type" => "ephemeral"})

  def compatible(body, request, config) do
    if URI.parse(config.endpoint).host == "openrouter.ai" do
      body =
        case request[:session_id] do
          id when is_binary(id) and id != "" -> Map.put_new(body, "session_id", id)
          _ -> body
        end

      if String.starts_with?(config.model, ["anthropic/", "~anthropic/"]),
        do: anthropic(body, config.prompt_cache),
        else: body
    else
      body
    end
  end
end
