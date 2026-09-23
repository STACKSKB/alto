defmodule Alto.Display do
  @moduledoc """
  Bounded, readable presentation of returned data; never evaluates diagnostic text.

  Secret redaction is a cosmetic, best-effort safeguard for known credential
  fields and token formats. It is not a secrecy boundary for arbitrary text.
  """

  @limit 8_000
  @items 30
  @depth 8
  @messages %{
    "api_key_missing" => "API key is missing. Configure this provider's credentials.",
    "model_discovery_not_supported" => "This provider does not support model discovery.",
    "timeout" => "The request timed out",
    "eacces" => "Permission denied",
    "eperm" => "Operation not permitted",
    "folder_already_exists" => "Folder already exists. Use Open folder.",
    "eexist" => "A file already exists at that path. Choose another name.",
    "enotdir" => "A parent path is a file, not a folder.",
    "erofs" => "This location is read-only.",
    "enospc" => "There is no free space to create the folder.",
    "enoent" => "File or folder not found",
    "econnrefused" => "Connection refused",
    "closed" => "Connection closed",
    "disconnected" => "Not connected",
    "invalid_workspace_path" => "Enter a folder path on one line",
    "project_not_directory" => "Folder does not exist or is not a directory",
    "unknown_workspace" => "Workspace is no longer available",
    "workspace_missing" => "Workspace folder no longer exists"
  }

  def text(value, opts \\ []), do: present(value, :text, opts)
  def result(value, opts \\ []), do: present(value, :result, opts)
  def error(value, opts \\ []), do: present(value, :error, opts)

  defp present(value, mode, opts) do
    value |> render(mode, 0) |> clean() |> bound(Keyword.get(opts, :limit, @limit))
  end

  def label(value) when is_atom(value), do: value |> Atom.to_string() |> label()

  def label(value) when is_binary(value) do
    value
    |> String.replace_prefix("Elixir.", "")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> then(fn text ->
      case String.next_grapheme(text) do
        {first, rest} -> String.upcase(first) <> rest
        nil -> "Details"
      end
    end)
  end

  def label(_), do: "Details"

  defp render(_, _, depth) when depth > @depth, do: "…"
  defp render(nil, _, _), do: ""
  defp render(true, _, _), do: "Yes"
  defp render(false, _, _), do: "No"
  defp render(value, _, _) when is_number(value), do: to_string(value)
  defp render(value, _, _) when is_atom(value), do: reason_label(value)

  defp render(value, mode, depth) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        "Received non-text data"

      mode == :text ->
        value

      true ->
        case decoded(value) do
          {:ok, data} -> render(data, mode, depth + 1)
          :plain -> if(mode == :error, do: error_text(clean(value)), else: value)
        end
    end
  end

  defp render(%{"$tuple" => parts}, mode, depth) when is_list(parts),
    do: render(List.to_tuple(parts), mode, depth + 1)

  defp render(%{"$inspect" => _}, _, _), do: "Diagnostic details are unavailable"

  defp render(%{__exception__: true, message: message}, mode, depth) when is_binary(message),
    do: render(message, mode, depth + 1)

  defp render(%Alto.Credentials{}, _, _), do: "Credentials hidden"

  defp render(%Alto.Content{blocks: blocks}, mode, depth) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} ->
        render(text, :text, depth + 1)

      %{"type" => "image", "media_type" => type, "width" => width, "height" => height} ->
        "Image · #{type} · #{width} × #{height}"

      other ->
        render(other, mode, depth + 1)
    end)
  end

  defp render(%_{} = value, mode, depth), do: render(Map.from_struct(value), mode, depth + 1)

  defp render(value, mode, depth) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.reject(fn {key, _} ->
      key_name(key) in ["__struct__", "__exception__", "stacktrace", "stack_trace"]
    end)
    |> Enum.sort_by(fn {key, _} ->
      {if(key_name(key) in ["message", "error", "reason"], do: 0, else: 1), key_name(key)}
    end)
    |> entries(fn {key, item} ->
      name = key_name(key)

      formatted =
        cond do
          secret?(name) ->
            "[REDACTED]"

          name in ["stdout", "stderr", "content", "diff", "command", "path", "cwd"] ->
            render(item, :text, depth + 1)

          name in ["error", "reason"] ->
            render(item, :error, depth + 1)

          name in ["code", "type", "status"] and is_binary(item) ->
            label(item)

          true ->
            render(item, mode, depth + 1)
        end

      label(key) <> ": " <> String.replace(formatted, "\n", "\n  ")
    end)
  end

  defp render({tag, reason}, mode, depth) when tag in [:error, "error", :ok, "ok"],
    do: render(reason, mode, depth + 1)

  defp render({tag, _provider}, _, _)
       when tag in [:model_discovery_not_supported, "model_discovery_not_supported"],
       do: @messages["model_discovery_not_supported"]

  defp render({tag, error, _stacktrace}, mode, depth)
       when tag in [:provider_exception, "provider_exception", :exception, "exception"],
       do: "Provider failed: " <> render(error, mode, depth + 1)

  defp render({tag, status, detail}, mode, depth) when tag in [:http_error, "http_error"],
    do:
      "Provider returned HTTP #{render(status, :text, depth + 1)}\n" <>
        render(detail, mode, depth + 1)

  defp render({tag, code, detail}, mode, depth) when tag in [:server, "server"],
    do: reason_label(code) <> "\n" <> render(detail, mode, depth + 1)

  defp render(value, mode, depth) when is_tuple(value) do
    case Tuple.to_list(value) do
      [tag | details] when is_atom(tag) or is_binary(tag) ->
        reason_label(tag) <>
          if(details == [],
            do: "",
            else: ": " <> entries(details, &render(&1, mode, depth + 1))
          )

      items ->
        render(items, mode, depth + 1)
    end
  end

  defp render(value, mode, depth) when is_list(value) do
    if Keyword.keyword?(value) and value != [] do
      render(Map.new(value), mode, depth + 1)
    else
      entries(value, &("• " <> render(&1, mode, depth + 1)))
    end
  end

  defp render(_, _, _), do: "Details unavailable"

  defp entries(items, fun) do
    {lines, _} =
      items
      |> Enum.take(@items)
      |> Enum.reduce_while({[], 0}, fn item, {lines, size} ->
        line = bound(fun.(item), @limit)

        if size + byte_size(line) > @limit,
          do: {:halt, {[bound(line, max(@limit - size - 1, 0)) | lines], @limit}},
          else: {:cont, {[line | lines], size + byte_size(line) + 1}}
      end)

    Enum.reverse(lines)
    |> Enum.join("\n")
    |> Kernel.<>(if(length(items) > @items, do: "\n…", else: ""))
  end

  defp error_text(value) do
    code = String.trim_leading(value, ":")

    cond do
      Map.has_key?(@messages, code) -> Map.fetch!(@messages, code)
      Regex.match?(~r/^[a-z]+(?:_[a-z0-9]+)+$/, code) -> label(code)
      true -> value
    end
  end

  defp reason_label(value), do: Map.get(@messages, key_name(value), label(value))
  defp key_name(value) when is_atom(value), do: Atom.to_string(value)
  defp key_name(value) when is_binary(value), do: value
  defp key_name(value) when is_number(value), do: to_string(value)
  defp key_name(_), do: "details"

  defp secret?(key),
    do:
      Regex.match?(
        ~r/^(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|cookie)$/i,
        key
      )

  # Structured diagnostics use JSON. All other strings remain literal text.
  defp decoded(text) do
    if byte_size(text) <= @limit do
      case JSON.decode(text) do
        {:ok, value} when is_map(value) or is_list(value) -> {:ok, value}
        _ -> :plain
      end
    else
      :plain
    end
  end

  defp clean(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
    |> String.replace(~r/\b(?:sk-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9_]+)\b/, "[REDACTED]")
    |> String.replace(~r/(?i)(authorization:\s*basic\s+)[^\s"',}\]]+/, "\\1[REDACTED]")
    |> String.replace(~r/(?i)(bearer\s+)[^\s"',}\]]+/, "\\1[REDACTED]")
    |> String.replace(
      ~r/(?i)(x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)(\s*[:=]\s*)[^\s"',}\]]+/,
      "\\1\\2[REDACTED]"
    )
  end

  defp bound(text, limit), do: Alto.Text.truncate(text, limit, "…")
end
