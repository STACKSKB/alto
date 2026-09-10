defmodule Alto.CLI.Onboarding do
  @moduledoc false

  alias Alto.Credentials

  @provider_id "openrouter"
  @display_limit 30

  @spec resolve(keyword()) ::
          {:ok, %{api_key: String.t(), model: String.t()}} | {:error, term()}
  def resolve(opts) do
    input = Keyword.get(opts, :input, :standard_io)
    output = Keyword.get(opts, :output, :standard_error)
    interactive? = Keyword.get(opts, :interactive, terminal?(input))
    force? = Keyword.get(opts, :force, false)
    credentials_path = Keyword.get(opts, :credentials_path, Credentials.default_path())

    with {:ok, credentials} <- Credentials.load(credentials_path),
         {:ok, api_key, credentials} <-
           resolve_api_key(credentials, opts[:api_key], force?, interactive?, input, output),
         {:ok, model, _credentials} <-
           resolve_model(
             credentials,
             opts[:model],
             api_key,
             force?,
             interactive?,
             input,
             output,
             opts
           ) do
      {:ok, %{api_key: api_key, model: model}}
    end
  end

  @spec terminal?(term()) :: boolean()
  def terminal?(device \\ :standard_io) do
    case :io.getopts(device) do
      opts when is_list(opts) ->
        Keyword.get(opts, :terminal, false) and Keyword.get(opts, :stdin, false)

      _other ->
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp resolve_api_key(credentials, supplied, false, _interactive?, _input, _output)
       when is_binary(supplied) and supplied != "" do
    {:ok, supplied, credentials}
  end

  defp resolve_api_key(credentials, _supplied, false, interactive?, input, output) do
    case Credentials.get(credentials, @provider_id, "api_key") do
      key when is_binary(key) ->
        {:ok, key, credentials}

      nil when interactive? ->
        prompt_for_api_key(credentials, nil, false, input, output)

      nil ->
        {:error,
         "OpenRouter API key required; set OPENROUTER_API_KEY or run `alto --setup` in a terminal"}
    end
  end

  defp resolve_api_key(credentials, supplied, force?, true, input, output) do
    fallback = Credentials.get(credentials, @provider_id, "api_key") || supplied
    prompt_for_api_key(credentials, fallback, force?, input, output)
  end

  defp resolve_api_key(_credentials, _supplied, _force?, false, _input, _output) do
    {:error,
     "OpenRouter API key required; set OPENROUTER_API_KEY or run `alto --setup` in a terminal"}
  end

  defp prompt_for_api_key(credentials, fallback, allow_fallback?, input, output) do
    suffix = if allow_fallback? and fallback, do: " (Enter keeps the current key)", else: ""
    IO.write(output, "OpenRouter API key#{suffix}: ")

    case :io.get_password(input) do
      value when is_list(value) or is_binary(value) ->
        entered = value |> IO.iodata_to_binary() |> String.trim()
        key = if entered == "" and allow_fallback?, do: fallback, else: entered

        if is_binary(key) and key != "" do
          if entered == "" do
            {:ok, key, credentials}
          else
            with {:ok, credentials} <-
                   Credentials.put(credentials, @provider_id, %{"api_key" => key}) do
              IO.puts(output, "Saved OpenRouter credentials to #{credentials.path}")
              {:ok, key, credentials}
            end
          end
        else
          {:error, "OpenRouter API key cannot be empty"}
        end

      :eof ->
        {:error, "input closed while reading the OpenRouter API key"}

      {:error, reason} ->
        {:error, {:api_key_input_failed, reason}}
    end
  end

  defp resolve_model(
         credentials,
         supplied,
         _api_key,
         false,
         _interactive?,
         _input,
         _output,
         _opts
       )
       when is_binary(supplied) and supplied != "" do
    {:ok, supplied, credentials}
  end

  defp resolve_model(credentials, _supplied, api_key, false, interactive?, input, output, opts) do
    case Credentials.get(credentials, @provider_id, "model") do
      model when is_binary(model) -> {:ok, model, credentials}
      nil -> discover_model(credentials, api_key, interactive?, input, output, opts)
    end
  end

  defp resolve_model(credentials, _supplied, api_key, true, interactive?, input, output, opts) do
    discover_model(credentials, api_key, interactive?, input, output, opts)
  end

  defp discover_model(_credentials, _api_key, false, _input, _output, _opts) do
    {:error, "model required; set --model or ALTO_MODEL, or run `alto --setup` in a terminal"}
  end

  defp discover_model(credentials, api_key, true, input, output, opts) do
    provider = Keyword.fetch!(opts, :provider)
    IO.puts(output, "Fetching available models from OpenRouter…")

    provider_options =
      opts
      |> Keyword.get(:provider_options, [])
      |> Keyword.put(:api_key, api_key)

    with true <- function_exported?(provider, :list_models, 1),
         {:ok, models} <- provider.list_models(provider_options),
         {:ok, model} <- select_model(models, input, output),
         {:ok, credentials} <-
           Credentials.put(credentials, @provider_id, %{"model" => model}) do
      IO.puts(output, "Selected #{model}")
      {:ok, model, credentials}
    else
      false -> {:error, {:model_discovery_not_supported, provider}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_model(models, input, output) when is_list(models) and models != [] do
    IO.puts(output, "\nAvailable models (tool-capable, most popular first):")
    select_from(models, models, input, output)
  end

  defp select_model([], _input, _output), do: {:error, :empty_model_catalog}

  defp select_from(visible, all, input, output) do
    shown = Enum.take(visible, @display_limit)

    shown
    |> Enum.with_index(1)
    |> Enum.each(fn {model, index} ->
      IO.puts(output, "  #{index}. #{model.id} — #{model.name}#{context_suffix(model)}")
    end)

    if length(visible) > @display_limit do
      IO.puts(output, "  … #{length(visible) - @display_limit} more; type text to filter")
    end

    case IO.gets(input, "Select a model number, exact id, or filter: ") do
      value when is_binary(value) ->
        choose_model(String.trim(value), shown, all, input, output)

      :eof ->
        {:error, "input closed while selecting a model"}

      {:error, reason} ->
        {:error, {:model_input_failed, reason}}
    end
  end

  defp choose_model("", shown, all, input, output), do: select_from(shown, all, input, output)

  defp choose_model(value, shown, all, input, output) do
    case Integer.parse(value) do
      {index, ""} when index >= 1 and index <= length(shown) ->
        {:ok, Enum.at(shown, index - 1).id}

      _other ->
        case Enum.find(all, &(&1.id == value)) do
          %{id: id} ->
            {:ok, id}

          nil ->
            matches =
              Enum.filter(all, fn model ->
                contains_case_insensitive?(model.id, value) or
                  contains_case_insensitive?(model.name, value)
              end)

            case matches do
              [%{id: id}] ->
                {:ok, id}

              [] ->
                IO.puts(output, "No models matched #{inspect(value)}. Try again.")
                select_from(shown, all, input, output)

              many ->
                IO.puts(output, "\n#{length(many)} matching models:")
                select_from(many, all, input, output)
            end
        end
    end
  end

  defp contains_case_insensitive?(text, query) do
    String.contains?(String.downcase(text), String.downcase(query))
  end

  defp context_suffix(%{context_length: length}) when is_integer(length) do
    " · #{format_context(length)} context"
  end

  defp context_suffix(_model), do: ""

  defp format_context(length) when length >= 1_000_000,
    do: "#{Float.round(length / 1_000_000, 1)}M"

  defp format_context(length) when length >= 1_000, do: "#{div(length, 1_000)}k"
  defp format_context(length), do: Integer.to_string(length)
end
