defmodule Alto.Event do
  @moduledoc """
  A typed fact delivered to a loop.

  Durable events are intended for the future session store. Live events exist
  only while work is in flight. Sequence numbers are assigned by storage, not
  by producers.
  """

  @enforce_keys [:domain, :type, :data, :at_ms]
  defstruct [:domain, :type, :data, :at_ms, :seq]

  @type domain :: :durable | :live
  @type t :: %__MODULE__{
          domain: domain(),
          type: atom(),
          data: map(),
          at_ms: integer(),
          seq: non_neg_integer() | nil
        }

  @spec durable(atom(), map()) :: t()
  def durable(type, data \\ %{}), do: new(:durable, type, data)

  @spec live(atom(), map()) :: t()
  def live(type, data \\ %{}), do: new(:live, type, data)

  @spec with_seq(t(), non_neg_integer()) :: t()
  def with_seq(%__MODULE__{domain: :durable} = event, seq)
      when is_integer(seq) and seq >= 0 do
    %{event | seq: seq}
  end

  defp new(domain, type, data) when is_atom(type) and is_map(data) do
    %__MODULE__{
      domain: domain,
      type: type,
      data: data,
      at_ms: System.system_time(:millisecond),
      seq: nil
    }
  end
end
