defmodule Alto.TUI.ApprovalView do
  @moduledoc "Readable, display-only summaries of native and remote approval requests."

  @doc "Present the actual prepared action, including its folder and execution constraints."
  def text(request) do
    request = normalize(request)
    args = Map.get(request, "arguments") || %{}
    details = Map.get(request, "details") || %{}
    tool = Map.get(request, "tool", "Action")
    command = Map.get(details, "command") || Map.get(args, "command")

    cond do
      is_map(command) and is_binary(command["executable"]) ->
        command_text(command, details, args)

      tool in ["run_command", "Codex command"] or is_binary(command) or is_list(command) ->
        raw_command(command, details, args)

      tool in ["write_file", "edit_file"] ->
        file_text(tool, details, args)

      true ->
        human_label(tool) <> sections([{"Requested action", args}, {"Details", details}])
    end
  end

  defp command_text(command, details, args) do
    program = command["requested_program"] || command["executable"]

    "Run command\n\n" <>
      argv([program | command["args"] || []]) <>
      sections([
        {"Folder", command["cwd"]},
        {"Executable", if(program != command["executable"], do: command["executable"])},
        {"Reason", args["reason"] || details["reason"]},
        {"Timeout", duration(command["timeout_ms"])},
        {"Output limit", bytes(command["max_output_bytes"])},
        {"Execution", execution(details["execution"])}
      ])
  end

  defp raw_command(command, details, args) do
    line =
      cond do
        is_list(command) -> argv(command)
        is_binary(command) -> visible(command)
        is_binary(args["program"]) -> argv([args["program"] | args["args"] || []])
        true -> "Command not supplied"
      end

    "Run command\n\n" <>
      line <>
      sections([
        {"Folder", args["cwd"] || details["cwd"]},
        {"Reason", args["reason"] || details["reason"]},
        {"Timeout", duration(args["timeout_ms"])},
        {"Output limit", bytes(args["max_output_bytes"])},
        {"Execution", execution(details["execution"])},
        {"Additional details",
         Map.drop(details, [
           "command",
           "cwd",
           "reason",
           "execution",
           "threadId",
           "turnId",
           "itemId"
         ])}
      ])
  end

  defp file_text(tool, details, args) do
    title = if tool == "write_file", do: "Write file", else: "Edit file"

    title <>
      sections(
        [
          {"File", details["path"] || args["path"]},
          {"Size before", bytes(details["bytes_before"])},
          {"Size after", bytes(details["bytes_after"])},
          {"Replacements", details["replacements"]}
        ] ++ edit_sections(args["edits"]) ++ [{"Preview", details["preview"] || args["content"]}]
      )
  end

  defp edit_sections([edit]), do: [{"Find", edit["old_text"]}, {"Replace with", edit["new_text"]}]

  defp edit_sections(edits) when is_list(edits) do
    edits
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {edit, index} ->
      [{"Find #{index}", edit["old_text"]}, {"Replace with #{index}", edit["new_text"]}]
    end)
  end

  defp edit_sections(_), do: []

  defp execution(nil), do: nil

  defp execution(%{"backend" => "unsandboxed"} = execution),
    do:
      "On this host, without a sandbox" <>
        sections(Map.to_list(Map.drop(execution, ["backend", "isolation"])))

  defp execution(%{"backend" => "bubblewrap"} = execution),
    do: "In a sandbox" <> sections(Map.to_list(Map.delete(execution, "backend")))

  defp execution(other), do: other

  # Shell-style quoting makes argv boundaries visible; it is never executed.
  defp argv(parts), do: Enum.map_join(parts, " ", &quote_arg/1)

  defp quote_arg(arg) do
    arg = value(arg)

    cond do
      Regex.match?(~r/^[A-Za-z0-9_@%+=:,\.\/\-]+$/, arg) -> arg
      true -> "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  defp duration(n) when is_number(n) and rem(trunc(n), 1_000) == 0,
    do: "#{div(trunc(n), 1_000)} seconds"

  defp duration(n) when is_number(n), do: "#{n} ms"
  defp duration(_), do: nil
  defp bytes(n) when is_number(n), do: "#{n} bytes"
  defp bytes(_), do: nil

  defp sections(items) do
    items
    |> Enum.reject(fn {_, v} -> v in [nil, "", %{}, []] end)
    |> Enum.map_join(fn {label, v} -> "\n\n" <> human_label(label) <> "\n" <> value(v) end)
  end

  defp value(value) when is_binary(value), do: visible(value)

  defp value(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {k, v} ->
      human_label(k) <> ": " <> (value(v) |> String.replace("\n", "\n  "))
    end)
  end

  defp value(value) when is_list(value), do: Enum.map_join(value, "\n", &("• " <> value(&1)))
  defp value(nil), do: "Not specified"
  defp value(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("_", " ")
  defp value(value) when is_number(value), do: to_string(value)
  defp value(_), do: "Not available"

  defp human_label(label) do
    label
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace_prefix("Codex ", "")
    |> then(fn text ->
      case String.next_grapheme(text) do
        {first, rest} -> String.upcase(first) <> rest
        nil -> "Action"
      end
    end)
  end

  # Keep control characters visible instead of allowing them to alter the display.
  defp visible(text),
    do:
      String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F]/u, fn c ->
        "\\u" <>
          (c
           |> :binary.first()
           |> Integer.to_string(16)
           |> String.downcase()
           |> String.pad_leading(4, "0"))
      end)

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize(v)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize()

  defp normalize(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp normalize(value), do: value
end
