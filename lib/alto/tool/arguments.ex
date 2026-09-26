defmodule Alto.Tool.Arguments do
  @moduledoc false

  # Closed projection of built-in argument contracts; remote/custom JSON
  # schemas remain opaque. Validation never creates atoms from supplied keys.
  def validate(arguments, fields) when is_map(arguments) do
    names = Map.new(fields, fn {key, _} -> {Atom.to_string(key), key} end)

    if Enum.all?(Map.keys(arguments), &Map.has_key?(names, &1)) do
      values = Enum.map(arguments, fn {name, value} -> {names[name], value} end)

      with {:ok, values} <- NimbleOptions.validate(values, fields),
           do: {:ok, Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end)}
    else
      {:error, :unknown_tool_argument}
    end
  end

  def validate(_, _), do: {:error, :tool_arguments_must_be_object}

  def schema({description, fields}) do
    properties =
      Map.new(fields, fn {key, field} ->
        property =
          Enum.reduce(Keyword.take(field, [:doc, :default]), type(field[:type]), fn
            {:doc, text}, schema -> Map.update(schema, :description, text, &(text <> " " <> &1))
            {:default, value}, schema -> Map.put(schema, :default, value)
          end)

        {key, property}
      end)

    required = for {key, field} <- fields, field[:required], do: Atom.to_string(key)
    Alto.Tool.object_schema(description, properties, required)
  end

  def text(minimum, maximum), do: {:custom, __MODULE__, :text, [minimum, maximum]}
  def list(item, minimum, maximum), do: {:custom, __MODULE__, :list, [item, minimum, maximum]}
  def object(fields), do: {:custom, __MODULE__, :object, [fields]}

  def text(value, minimum, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) >= minimum and
         (maximum == :infinity or byte_size(value) <= maximum),
       do: {:ok, value},
       else: {:error, "expected bounded UTF-8 text"}
  end

  def list(value, item, minimum, maximum) do
    if is_list(value) and length(value) >= minimum and length(value) <= maximum do
      case NimbleOptions.validate([value: value], value: [type: {:list, item}]) do
        {:ok, result} -> {:ok, result[:value]}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, "expected bounded list"}
    end
  end

  def object(value, fields) do
    case validate(value, fields) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp type(:string), do: %{type: "string"}
  defp type(:boolean), do: %{type: "boolean"}
  defp type(:integer), do: %{type: "integer"}
  defp type(:non_neg_integer), do: %{type: "integer", minimum: 0}
  defp type(:pos_integer), do: %{type: "integer", minimum: 1}
  defp type({:map, :any, :any}), do: %{type: "object"}

  defp type({:in, %Range{first: first, last: last}}),
    do: %{type: "integer", minimum: first, maximum: last}

  defp type({:in, values}), do: %{type: "string", enum: values}

  defp type({:custom, __MODULE__, :text, [minimum, maximum]}) do
    property = %{
      type: "string",
      minLength: minimum,
      description: "UTF-8 byte length: #{minimum}..#{maximum}."
    }

    if maximum == :infinity, do: property, else: Map.put(property, :maxLength, maximum)
  end

  defp type({:custom, __MODULE__, :list, [item, minimum, maximum]}),
    do: %{type: "array", items: type(item), minItems: minimum, maxItems: maximum}

  defp type({:custom, __MODULE__, :object, [fields]}),
    do: schema({"", fields}).parameters

  defp type({:or, [item, {:in, [nil]}]}),
    do: %{anyOf: [type(item), %{type: "null"}]}
end
