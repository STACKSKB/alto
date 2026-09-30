defmodule Alto.Contrib.ToolDisplay do
  @moduledoc "Bounded, shared presentation of tool calls and their results."

  def summary(name, arguments) do
    args = decode(arguments)
    name = to_string(name || "tool")
    target = first(args, ~w(path file_path pattern query)a)

    parts =
      case name do
        git when git in ["git_inspect", "git_mutate"] ->
          ["git", get(args, :action), get(args, :ref), target, get(args, :branch)]

        "run_shell" ->
          ["shell:", get(args, :command)]

        "run_command" ->
          program = first(args, ~w(program command)a) || name
          argv = [program | List.wrap(get(args, :args))]
          ["argv:", program, JSON.encode!(Enum.drop(argv, 1))]

        _ ->
          [name, target, range(args)]
      end

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(" ", &Alto.Contrib.Display.text(&1, limit: 300))
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, 500)
  end

  def entry(type, data) do
    name = get(data, :name) || "tool"
    title = get(data, :summary) || summary(name, get(data, :arguments))
    output = Map.get(data, :value, Map.get(data, "value"))

    case to_string(type) do
      "tool_started" ->
        %{kind: :tool, text: title <> " …"}

      "tool_failed" ->
        %{
          kind: :error,
          text: title <> " failed",
          detail: Alto.Contrib.Display.error(get(data, :error))
        }

      _ ->
        completed(name, title, output)
    end
  end

  defp completed(name, title, value)
       when name in [:run_command, "run_command", :run_shell, "run_shell"] do
    result = decode(value)
    status = get(result, :exit_status)
    timed_out? = get(result, :timed_out) == true

    cond do
      timed_out? ->
        %{kind: :error, text: title <> " timed out", detail: result_detail(name, value)}

      is_integer(status) and status != 0 ->
        %{
          kind: :error,
          text: title <> " failed (exit #{status})",
          detail: result_detail(name, value)
        }

      true ->
        %{kind: :tool, text: title <> " ✓", detail: result_detail(name, value)}
    end
  end

  defp completed(name, title, value),
    do: %{kind: :tool, text: title <> " ✓", detail: result_detail(name, value)}

  # Read results remain intact in the model/session; the terminal shows metadata.
  defp result_detail(name, value) when name in ["read_file", :read_file] do
    value = decode(value)
    content = get(value, :content)
    size = if is_binary(content), do: byte_size(content), else: nil

    label =
      if get(value, :encoding) == "base64",
        do: "Binary file read",
        else: if(size, do: "#{size} bytes read", else: "File read")

    label <> if(get(value, :truncated), do: " · more available", else: "")
  end

  defp result_detail(_, value) when is_list(value), do: content_text(value)
  defp result_detail(_, value), do: detail(value)

  def detail(value) do
    value = decode(value)
    patch = get(value, :patch)
    output = first(value, ~w(output content)a)

    cond do
      is_map(patch) ->
        Alto.Contrib.Display.text(get(patch, :content) || "", limit: 20_000) <>
          if(get(patch, :truncated), do: "\n[diff shortened]", else: "")

      is_binary(output) ->
        Alto.Contrib.Display.text(output, limit: 20_000)

      true ->
        Alto.Contrib.Display.result(value, limit: 20_000)
    end
  end

  def transcript(messages, opts \\ []) do
    {entries, _calls} =
      Enum.flat_map_reduce(messages, %{}, fn message, calls ->
        {entries, calls} = transcript_entry(message, calls)
        {entries ++ output_entries(message, opts), calls}
      end)

    entries
  end

  defp output_entries(%{"role" => role, "content" => blocks}, opts)
       when role in ["assistant", "tool"] and is_list(blocks) do
    if directory = opts[:attachment_directory] do
      case Alto.Contrib.Attachment.materialize(blocks, directory: directory) do
        {:ok, files} ->
          Enum.map(files, &%{kind: :system, text: "Output: #{&1.name}\n#{&1.path}"})

        {:error, reason} ->
          [%{kind: :error, text: "Cannot restore output: #{Alto.Contrib.Display.error(reason)}"}]
      end
    else
      []
    end
  end

  defp output_entries(_, _), do: []

  defp transcript_entry(%{"role" => "assistant"} = message, calls) do
    calls =
      Enum.reduce(message["tool_calls"] || [], calls, fn call, acc ->
        function = call["function"] || %{}
        name = function["name"]
        Map.put(acc, call["id"], {name, summary(name, function["arguments"])})
      end)

    content = message["content"]

    assistant =
      if content not in [nil, "", []],
        do: [%{kind: :assistant, text: content_text(content)}],
        else: []

    {Alto.Reasoning.entries(message) ++ assistant, calls}
  end

  defp transcript_entry(%{"role" => "user"} = message, calls),
    do: {[%{kind: :user, text: user_content_text(message["content"])}], calls}

  defp transcript_entry(%{"role" => "tool"} = message, calls) do
    name = message["name"]
    {name, title} = Map.get(calls, message["tool_call_id"], {name, name || "tool"})
    {[completed(name, title, message["content"])], calls}
  end

  defp transcript_entry(_, calls), do: {[], calls}

  defp content_text(blocks) when is_list(blocks) do
    case Alto.Content.decode_transcript(blocks) do
      {:ok, content} -> Alto.Content.text_value(content)
      _ -> Alto.Contrib.Display.text(blocks)
    end
  end

  defp content_text(value), do: Alto.Contrib.Display.text(value)

  defp user_content_text([first | rest] = blocks) do
    case Alto.Content.decode_transcript(blocks) do
      {:ok, _} ->
        rest =
          Enum.map(rest, fn
            %{"type" => "text", "text" => "Attached file: " <> text} ->
              name = text |> String.split("\n", parts: 2) |> hd()
              Alto.Content.text("[File · #{name} · text/plain]")

            block ->
              block
          end)

        Alto.Content.text_value([first | rest])

      _ ->
        content_text(blocks)
    end
  end

  defp user_content_text(value), do: content_text(value)

  defp range(args) do
    case {get(args, :start_line), get(args, :line_count), get(args, :offset)} do
      {start_line, line_count, _offset} when is_integer(start_line) and is_integer(line_count) ->
        last_line = start_line + line_count - 1
        "(lines #{start_line}–#{last_line})"

      {start_line, _line_count, _offset} when is_integer(start_line) ->
        "(from line #{start_line})"

      {_start_line, _line_count, offset} when is_integer(offset) ->
        "(byte #{offset})"

      _ ->
        nil
    end
  end

  defp first(data, keys), do: Enum.find_value(keys, &get(data, &1))

  defp decode(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> value
    end
  end

  defp decode(value), do: value

  defp get(map, key) when is_map(map),
    do: Map.get(map, Atom.to_string(key)) || Map.get(map, key)

  defp get(_, _), do: nil
end
