defmodule Alto.Display do
  @moduledoc "Bounded, readable presentation of returned data; never evaluates diagnostic text."

  @limit 8_000
  @items 30
  @depth 8
  @messages %{
    "api_key_missing" => "API key is missing. Configure this provider's credentials.",
    "model_discovery_not_supported" => "This provider does not support model discovery.",
    "timeout" => "The request timed out",
    "eacces" => "Permission denied",
    "eperm" => "Operation not permitted",
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
          :invalid_diagnostic -> "Diagnostic details are unavailable"
          :plain -> if(mode == :error, do: error_text(value), else: value)
        end
    end
  end

  defp render(%{"$tuple" => parts}, mode, depth) when is_list(parts),
    do: render(List.to_tuple(parts), mode, depth + 1)

  defp render(%{"$inspect" => _}, _, _), do: "Diagnostic details are unavailable"

  defp render(%{__exception__: true, message: message}, mode, depth) when is_binary(message),
    do: render(message, mode, depth + 1)

  defp render(%Alto.Credentials{}, _, _), do: "Credentials hidden"
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

  # Decode only complete data literals from machine-generated results. No evaluation,
  # function calls, or creation of atoms from untrusted diagnostic strings.
  defp decoded(text) do
    value = String.trim(text)

    cond do
      byte_size(value) > @limit ->
        if String.starts_with?(value, ["%", "{", "["]), do: :invalid_diagnostic, else: :plain

      String.starts_with?(value, ["{", "["]) ->
        case JSON.decode(value) do
          {:ok, parsed} when is_map(parsed) or is_list(parsed) -> {:ok, parsed}
          _ -> literal(value)
        end

      String.starts_with?(value, "%") ->
        literal(value)

      true ->
        :plain
    end
  end

  defp literal(text) do
    if String.starts_with?(text, ["%{", "{:"]) or Regex.match?(~r/^%[A-Z][\w.]*\{/, text) do
      with {:ok, ast} <- Code.string_to_quoted(text, existing_atoms_only: true),
           {:ok, value} <- data_literal(ast) do
        {:ok, value}
      else
        _ -> :invalid_diagnostic
      end
    else
      :plain
    end
  end

  defp data_literal({:%{}, _, pairs}) do
    with {:ok, pairs} <- literals(pairs), do: {:ok, Map.new(pairs)}
  end

  defp data_literal({:%, _, [_module, map]}), do: data_literal(map)

  defp data_literal({:{}, _, items}) do
    with {:ok, items} <- literals(items), do: {:ok, List.to_tuple(items)}
  end

  defp data_literal({:-, _, [n]}) when is_number(n), do: {:ok, -n}

  defp data_literal({a, b}) do
    with {:ok, a} <- data_literal(a), {:ok, b} <- data_literal(b), do: {:ok, {a, b}}
  end

  defp data_literal(items) when is_list(items), do: literals(items)

  defp data_literal(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: {:ok, value}

  defp data_literal(_), do: :error

  defp literals(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, values} ->
      case data_literal(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp clean(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
    |> String.replace(~r/(?i)(bearer\s+)[^\s"',}\]]+/, "\\1[REDACTED]")
  end

  defp bound(text, limit),
    do: if(String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text)
end
