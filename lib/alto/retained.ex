defmodule Alto.Retained do
  @moduledoc false

  # Detach small long-lived views of large read/JSON buffers, preserving useful
  # sharing when most of the allocation is still wanted.
  def detach(value) when is_binary(value) do
    backing = :binary.referenced_byte_size(value)
    if backing >= 4096 and backing > 4 * byte_size(value), do: :binary.copy(value), else: value
  end

  def detach(value) when is_list(value), do: Enum.map(value, &detach/1)

  def detach(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {detach(k), detach(v)} end)

  def detach(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&detach/1) |> List.to_tuple()

  def detach(value), do: value
end
