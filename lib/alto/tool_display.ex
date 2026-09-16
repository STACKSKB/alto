defmodule Alto.ToolDisplay do
  @moduledoc "Bounded, shared presentation of tool calls and their results."

  def summary(name, arguments) do
    args = decode(arguments)
    name = to_string(name || "tool")

    target =
      get(args, "path") || get(args, "file_path") || get(args, "pattern") || get(args, "query")

    parts =
      cond do
        name in ["git_inspect", "git_mutate"] ->
          ["git", get(args, "action"), get(args, "ref"), target, get(args, "branch")]

        name == "run_command" ->
          [get(args, "program") || get(args, "command") || name | List.wrap(get(args, "args"))]

        true ->
          [name, target, range(args)]
      end

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(" ", &Alto.Display.text(&1, limit: 300))
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, 500)
  end

  def entry(type, data) do
    name = get(data, "name") || "tool"
    title = get(data, "summary") || summary(name, get(data, "arguments"))
    output = get(data, "value") || get(data, "output")

    case to_string(type) do
      "tool_started" ->
        %{kind: :tool, text: title <> " …"}

      "tool_failed" ->
        %{kind: :error, text: title <> " failed", detail: Alto.Display.error(get(data, "error"))}

      _ ->
        %{kind: :tool, text: title <> " ✓", detail: detail(output)}
    end
  end

  def detail(value) do
    value = decode(value)
    patch = get(value, "patch")
    output = get(value, "output") || get(value, "content")

    cond do
      is_map(patch) ->
        Alto.Display.text(get(patch, "content") || "", limit: 20_000) <>
          if(get(patch, "truncated"), do: "\n[diff shortened]", else: "")

      is_binary(output) ->
        Alto.Display.text(output, limit: 20_000)

      true ->
        Alto.Display.result(value, limit: 20_000)
    end
  end

  def transcript(messages) do
    {entries, _calls} =
      Enum.map_reduce(messages, %{}, fn message, calls ->
        case message["role"] do
          "assistant" ->
            calls =
              Enum.reduce(message["tool_calls"] || [], calls, fn call, acc ->
                function = call["function"] || %{}
                Map.put(acc, call["id"], summary(function["name"], function["arguments"]))
              end)

            entries =
              Alto.Reasoning.entries(message) ++
                if(is_binary(message["content"]) and message["content"] != "",
                  do: [%{kind: :assistant, text: message["content"]}],
                  else: []
                )

            {entries, calls}

          "user" ->
            {[%{kind: :user, text: Alto.Display.text(message["content"])}], calls}

          "tool" ->
            title = Map.get(calls, message["tool_call_id"], message["name"] || "tool")
            {[%{kind: :tool, text: title <> " ✓", detail: detail(message["content"])}], calls}

          _ ->
            {[], calls}
        end
      end)

    List.flatten(entries)
  end

  defp range(args) do
    first = get(args, "offset") || get(args, "line_start")
    if first, do: "(from #{first})"
  end

  defp decode(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> value
    end
  end

  defp decode(value), do: value

  defp get(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn {k, v} -> if is_atom(k) and Atom.to_string(k) == key, do: v end)
  end

  defp get(_, _), do: nil
end
