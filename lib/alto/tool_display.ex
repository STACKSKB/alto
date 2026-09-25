defmodule Alto.ToolDisplay do
  @moduledoc "Bounded, shared presentation of tool calls and their results."

  @behaviour Alto.ToolPresentation
  @impl true
  def summary(name, arguments, _opts), do: summary(name, arguments)

  def summary(name, arguments) do
    args = decode(arguments)
    name = to_string(name || "tool")
    target = first(args, ~w(path file_path pattern query))

    parts =
      case name do
        git when git in ["git_inspect", "git_mutate"] ->
          ["git", get(args, "action"), get(args, "ref"), target, get(args, "branch")]

        "run_command" ->
          [first(args, ~w(program command)) || name | List.wrap(get(args, "args"))]

        _ ->
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
    output = Map.get(data, :value, Map.get(data, "value"))

    case to_string(type) do
      "tool_started" ->
        %{kind: :tool, text: title <> " …"}

      "tool_failed" ->
        %{kind: :error, text: title <> " failed", detail: Alto.Display.error(get(data, "error"))}

      _ ->
        completed(name, title, output)
    end
  end

  defp completed(name, title, value),
    do: %{kind: :tool, text: title <> " ✓", detail: result_detail(name, value)}

  # Read results remain intact in the model/session; the terminal shows metadata.
  defp result_detail(name, value) when name in ["read_file", :read_file] do
    value = decode(value)
    content = get(value, "content")
    size = if is_binary(content), do: byte_size(content), else: nil

    label =
      if get(value, "encoding") == "base64",
        do: "Binary file read",
        else: if(size, do: "#{size} bytes read", else: "File read")

    label <> if(get(value, "truncated"), do: " · more available", else: "")
  end

  defp result_detail(_, value), do: detail(value)

  def detail(value) do
    value = decode(value)
    patch = get(value, "patch")
    output = first(value, ~w(output content))

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
    {entries, _calls} = Enum.map_reduce(messages, %{}, &transcript_entry/2)
    List.flatten(entries)
  end

  defp transcript_entry(%{"role" => "assistant"} = message, calls) do
    calls =
      Enum.reduce(message["tool_calls"] || [], calls, fn call, acc ->
        function = call["function"] || %{}
        name = function["name"]
        Map.put(acc, call["id"], {name, summary(name, function["arguments"])})
      end)

    content = message["content"]

    assistant =
      if is_binary(content) and content != "", do: [%{kind: :assistant, text: content}], else: []

    {Alto.Reasoning.entries(message) ++ assistant, calls}
  end

  defp transcript_entry(%{"role" => "user"} = message, calls),
    do: {[%{kind: :user, text: Alto.Display.text(message["content"])}], calls}

  defp transcript_entry(%{"role" => "tool"} = message, calls) do
    name = message["name"]
    {name, title} = Map.get(calls, message["tool_call_id"], {name, name || "tool"})
    {[completed(name, title, message["content"])], calls}
  end

  defp transcript_entry(_, calls), do: {[], calls}

  defp range(args) do
    first = first(args, ~w(offset line_start))
    if first, do: "(from #{first})"
  end

  defp first(data, keys), do: Enum.find_value(keys, &get(data, &1))

  defp decode(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> value
    end
  end

  defp decode(value), do: value

  defp get(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(Map.to_list(map), fn {k, v} ->
        if is_atom(k) and Atom.to_string(k) == key, do: v
      end)
  end

  defp get(_, _), do: nil
end
