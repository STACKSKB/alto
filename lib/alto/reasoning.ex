defmodule Alto.Reasoning do
  @moduledoc "Provider-advertised effort choices and request parameter mapping."
  @gateway_efforts ~w(none minimal low medium high xhigh max)

  def efforts(nil), do: []

  def efforts(model) when is_map(model) do
    reasoning = get(model, :reasoning) || %{}
    explicit = get(model, :efforts) || get(model, :supported_reasoning_efforts)

    choices =
      cond do
        is_list(explicit) ->
          explicit

        Map.has_key?(reasoning, "supported_efforts") or
            Map.has_key?(reasoning, :supported_efforts) ->
          get(reasoning, :supported_efforts) || @gateway_efforts

        true ->
          []
      end

    choices
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_map(value) -> get(value, :reasoningEffort) || get(value, :effort)
      _ -> nil
    end)
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..32))
    |> Enum.reject(&(get(reasoning, :mandatory) == true and &1 == "none"))
    |> Enum.uniq()
  end

  def apply_options(options, _format, nil), do: options

  def apply_options(options, :openrouter, effort),
    do:
      Map.update(
        options,
        "reasoning",
        %{"effort" => effort, "exclude" => false},
        &Map.merge(&1, %{"effort" => effort, "exclude" => false})
      )

  def apply_options(options, :anthropic, effort),
    do:
      Map.update(options, "output_config", %{"effort" => effort}, &Map.put(&1, "effort", effort))

  def apply_options(options, :openai, effort), do: Map.put(options, "reasoning_effort", effort)

  def format(opts) do
    Keyword.get_lazy(opts, :reasoning_format, fn ->
      url = Keyword.get(opts, :base_url, "https://openrouter.ai/api/v1")
      if URI.parse(url).host == "openrouter.ai", do: :openrouter, else: :openai
    end)
  end

  @doc "Apply a host-validated effort to a run's configured provider."
  def configure_run(options, nil), do: options

  def configure_run(options, effort) when is_binary(effort) do
    Keyword.update!(options, :provider, fn
      {module, opts} -> {module, Keyword.put(opts, :reasoning_effort, effort)}
      module when is_atom(module) -> {module, [reasoning_effort: effort]}
    end)
  end

  @doc "Extract only readable provider reasoning, preferring structured text over duplicate aliases."
  def text(message) when is_map(message) do
    details = Map.get(message, "reasoning_details") || []

    structured =
      Enum.map_join(details, "", fn
        %{"type" => "reasoning.text", "text" => text} when is_binary(text) -> text
        %{"type" => "reasoning.summary", "summary" => text} when is_binary(text) -> text
        _ -> ""
      end)

    cond do
      structured != "" -> structured
      is_binary(message["reasoning"]) and message["reasoning"] != "" -> message["reasoning"]
      is_binary(message["reasoning_content"]) -> message["reasoning_content"]
      true -> ""
    end
  end

  def entries(message) do
    case text(message) do
      "" -> []
      text -> [%{kind: :reasoning, text: text}]
    end
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
