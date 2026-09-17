defmodule Alto.Context.Observation do
  @moduledoc false

  # Called with the description obtained inside the bounded provider call.
  # Only routing identity is retained, never credentials or arbitrary options.
  def identity(provider, opts, description) do
    model = Map.get(description, :model) || Keyword.get(opts, :model)

    if is_binary(model) and model != "" do
      endpoints =
        Enum.map([:endpoint, :base_url], fn key ->
          case Keyword.get(opts, key) do
            value when is_binary(value) ->
              uri = URI.parse(value)
              {key, uri.scheme, uri.host, uri.port, uri.path, uri.query}

            _ ->
              {key, nil}
          end
        end)

      %{
        "provider" => Atom.to_string(provider),
        "model" => model,
        "routing_sha256" => hash(endpoints)
      }
    end
  end

  def new(request, tokens) when is_integer(tokens) and tokens > 0 do
    %{
      messages: request.messages,
      tools: request.tools,
      input_tokens: tokens,
      identity: Map.get(request, :context_identity)
    }
  end

  def new(_, _), do: nil

  def dump(%{messages: prefix, tools: tools, input_tokens: tokens, identity: identity}, messages)
      when is_list(prefix) and is_list(tools) and is_integer(tokens) and tokens > 0 do
    if valid_identity?(identity) and prefix != [] and
         Enum.take(messages, length(prefix)) == prefix do
      %{
        "v" => 1,
        "messages_count" => length(prefix),
        "prefix_sha256" => hash(prefix),
        "tools_sha256" => hash(tools),
        "input_tokens" => tokens,
        "identity" => identity
      }
    end
  end

  def dump(_, _), do: nil

  def restore(metadata, messages, tools, identity) do
    with %{
           "v" => 1,
           "messages_count" => count,
           "input_tokens" => tokens,
           "prefix_sha256" => prefix_hash,
           "tools_sha256" => tools_hash,
           "identity" => previous_identity
         } <- metadata,
         true <- is_integer(count) and count > 0 and count <= length(messages),
         true <- is_integer(tokens) and tokens > 0,
         true <- valid_identity?(identity) and identity == previous_identity,
         prefix <- Enum.take(messages, count),
         true <- hash(prefix) == prefix_hash and hash(tools) == tools_hash do
      %{messages: prefix, tools: tools, input_tokens: tokens, identity: identity}
    else
      _ -> nil
    end
  end

  defp valid_identity?(
         %{"provider" => provider, "model" => model, "routing_sha256" => routing} = identity
       ),
       do:
         map_size(identity) == 3 and is_binary(provider) and provider != "" and
           is_binary(model) and model != "" and is_binary(routing) and byte_size(routing) == 64

  defp valid_identity?(_), do: false

  defp hash(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)
end
