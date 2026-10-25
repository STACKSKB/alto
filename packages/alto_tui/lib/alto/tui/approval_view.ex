defmodule Alto.TUI.ApprovalView do
  @moduledoc "Readable, display-only summaries of native and remote approval requests."

  @doc "Present the actual prepared action, including its folder and execution constraints."
  def text(request) do
    request = Alto.Contrib.Protocol.encode_term(request)
    args = Map.get(request, "arguments") || %{}
    details = Map.get(request, "details") || %{}
    tool = Map.get(request, "tool", "Action")
    command = Map.get(details, "command") || Map.get(args, "command")

    cond do
      (is_map(command) and is_binary(command["executable"])) or
        tool in ["run_command", "Codex command"] or is_binary(command) or is_list(command) ->
        command_text(command, details, args)

      tool in ["write_file", "edit_file"] ->
        file_text(tool, details, args)

      true ->
        Alto.Contrib.Display.label(tool) <>
          sections([{"Requested action", args} | Enum.sort(Map.to_list(details))])
    end
  end

  defp command_text(command, details, args) do
    {line, settings, executable, additional} =
      case command do
        %{"executable" => executable} when is_binary(executable) ->
          program = command["requested_program"] || executable

          {argv([program | command["args"] || []]), command,
           if(program != executable, do: executable), nil}

        _ ->
          {raw_command(command, args), Map.put(args, "cwd", args["cwd"] || details["cwd"]), nil,
           Map.drop(details, ~w(command cwd reason execution threadId turnId itemId))}
      end

    "Run command\n\n" <>
      line <>
      sections([
        {"Folder", settings["cwd"]},
        {"Executable", executable},
        {"Reason", args["reason"] || details["reason"]},
        {"Timeout", duration(settings["timeout_ms"])},
        {"Output limit", bytes(settings["max_output_bytes"])},
        {"Execution", execution(details["execution"])},
        {"Additional details", additional}
      ])
  end

  defp raw_command(command, args) do
    cond do
      is_list(command) -> argv(command)
      is_binary(command) -> visible(command)
      is_binary(args["program"]) -> argv([args["program"] | args["args"] || []])
      true -> "Command not supplied"
    end
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
        ] ++
          edit_sections(args["edits"]) ++
          [{"Preview", preview(details["preview"] || args["content"])}]
      )
  end

  defp preview(%{"content" => content} = preview) when is_binary(content) do
    content <>
      if(preview["truncated"] == true,
        do: "\n\n[Preview truncated; showing the first #{byte_size(content)} bytes.]",
        else: ""
      )
  end

  defp preview(content) when is_binary(content) or is_nil(content), do: content
  defp preview(other), do: Alto.Contrib.Display.result(other)

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
    |> Enum.map_join(fn {label, v} ->
      "\n\n" <> Alto.Contrib.Display.label(label) <> "\n" <> value(v)
    end)
  end

  defp value(value) when is_binary(value), do: visible(value)

  defp value(value), do: JSON.encode!(value)

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
end
