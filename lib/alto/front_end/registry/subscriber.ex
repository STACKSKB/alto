defmodule Alto.FrontEnd.Registry.Subscriber do
  @moduledoc "Bounded subscriber buffering and delivery transitions, independent of registry ownership."

  @enforce_keys [:monitor, :run_id, :domains, :max_buffer_messages]
  defstruct [
    :monitor,
    :run_id,
    :domains,
    :max_buffer_messages,
    buffer: {[], []},
    buffered_count: 0,
    buffered_bytes: 0,
    max_buffer_bytes: 8_000_000,
    overflow: [],
    last_durable_seq: %{},
    closed?: false
  ]

  def interested?(%__MODULE__{run_id: selected, domains: domains}, run_id, domain) do
    (is_nil(selected) or selected == run_id) and
      (domain == :approval or domain == :result or MapSet.member?(domains, domain))
  end

  def enqueue(subscriber, notification) do
    bytes = :erlang.external_size(notification)

    if subscriber.buffered_count >= subscriber.max_buffer_messages or
         subscriber.buffered_bytes + bytes > subscriber.max_buffer_bytes do
      overflow =
        case notification do
          {:event, run_id, seq, _event} when is_integer(seq) ->
            {:durable, run_id, Map.get(subscriber.last_durable_seq, run_id)}

          {:event, run_id, nil, _event} ->
            {:live, run_id, nil}

          _other ->
            {:live, nil, nil}
        end

      markers =
        cond do
          {:durable, nil, nil} in subscriber.overflow -> subscriber.overflow
          overflow in subscriber.overflow -> subscriber.overflow
          length(subscriber.overflow) >= 100 -> [{:durable, nil, nil}, {:live, nil, nil}]
          true -> [overflow | subscriber.overflow]
        end

      %{subscriber | overflow: markers}
    else
      %{
        subscriber
        | buffer: :queue.in({notification, bytes}, subscriber.buffer),
          buffered_count: subscriber.buffered_count + 1,
          buffered_bytes: subscriber.buffered_bytes + bytes
      }
    end
  end

  def pull(subscriber, count, disconnect_after_overflow) do
    taken = min(max(count, 0), subscriber.buffered_count)
    {batch, rest} = :queue.split(taken, subscriber.buffer)
    pairs = :queue.to_list(batch)
    deliveries = Enum.map(pairs, &elem(&1, 0))
    bytes = Enum.reduce(pairs, 0, &(elem(&1, 1) + &2))
    messages = Enum.map(deliveries, &{:alto_notification, &1})

    subscriber =
      %{
        subscriber
        | buffer: rest,
          buffered_count: subscriber.buffered_count - taken,
          buffered_bytes: subscriber.buffered_bytes - bytes
      }
      |> note_delivered(deliveries)

    {overflow_batch, rest_overflow} = Enum.split(subscriber.overflow, count)

    overflow_notifications =
      Enum.map(overflow_batch, fn {domain, run_id, last_seq} ->
        {:alto_notification, {:overflow, run_id, domain, last_seq}}
      end)

    messages = messages ++ overflow_notifications

    subscriber = %{subscriber | overflow: rest_overflow}

    disconnect? =
      disconnect_after_overflow == :immediately and overflow_batch != [] and
        not subscriber.closed?

    if disconnect? do
      {%{subscriber | closed?: true}, messages ++ [:alto_close]}
    else
      {subscriber, messages}
    end
  end

  defp note_delivered(subscriber, deliveries) do
    last_durable_seq =
      Enum.reduce(deliveries, subscriber.last_durable_seq, fn
        {:event, run_id, seq, _event}, acc when is_integer(seq) ->
          Map.put(acc, run_id, seq)

        _other, acc ->
          acc
      end)

    %{subscriber | last_durable_seq: last_durable_seq}
  end
end
