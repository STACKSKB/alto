defmodule Alto.Event do
  @moduledoc """
  A typed fact delivered to a loop.

  Durable events are recorded in session history. Live events exist only while
  work is in flight. Hosts assign delivery sequence numbers outside the event.
  """

  @enforce_keys [:domain, :type, :data, :at_ms]
  defstruct [:domain, :type, :data, :at_ms]

  @type domain :: :durable | :live
  @type t :: %__MODULE__{
          domain: domain(),
          type: atom(),
          data: map(),
          at_ms: integer()
        }

  @spec durable(atom(), map()) :: t()
  def durable(type, data \\ %{}), do: new(:durable, type, data)

  @spec live(atom(), map()) :: t()
  def live(type, data \\ %{}), do: new(:live, type, data)

  defp new(domain, type, data) when is_atom(type) and is_map(data) do
    %__MODULE__{
      domain: domain,
      type: type,
      data: data,
      at_ms: System.system_time(:millisecond)
    }
  end
end
