defmodule Alto.Events.ObserverTest do
  use ExUnit.Case, async: true
  alias Alto.{Event, Events}
  alias Alto.Events.Observer

  test "admission stays responsive while accepted durable events and coalesced text retain order" do
    owner = self()

    sink = fn event ->
      send(owner, {:delivered, event, self()})
      if event.data[:block], do: receive(do: (:release -> :ok))
    end

    {:ok, observer} = Observer.open(sink, max_events: 3)
    first = Event.durable(:first, %{block: true})
    assert :ok = Observer.push(observer, first)
    assert_receive {:delivered, ^first, worker}
    assert :ok = Observer.push(observer, Event.live(:model_delta, %{text: "a", agent_id: "one"}))
    assert :ok = Observer.push(observer, Event.live(:model_delta, %{text: "b", agent_id: "one"}))
    last = Event.durable(:last)
    assert :ok = Observer.push(observer, last)
    send(worker, :release)
    assert {:ok, %{accepted: 4, delivered: 3, coalesced: 1}} = Observer.close(observer)
    assert_receive {:delivered, %{data: %{text: "ab"}}, _}
    assert_receive {:delivered, ^last, _}
  end

  test "overload is reported at admission and drain, without dropping accepted durable events" do
    owner = self()

    {:ok, observer} =
      Observer.open(
        fn event ->
          send(owner, {:entered, self(), event})
          receive do: (:release -> :ok)
        end,
        max_events: 1,
        callback_timeout: 1000
      )

    first = Event.durable(:first)
    assert :ok = Observer.push(observer, first)
    assert_receive {:entered, worker, ^first}
    assert {:error, :observer_overloaded} = Observer.push(observer, Event.durable(:last))
    send(worker, :release)

    assert {:error, %{delivered: 1, rejected: 1, errors: [:observer_overloaded]}} =
             Observer.close(observer)
  end

  test "callback deadlines bound delivery work and report failed delivery while later events continue" do
    owner = self()

    {result, status} =
      Events.with_buffered(
        fn event ->
          if event.type == :blocked, do: Process.sleep(5000), else: send(owner, event)
        end,
        [callback_timeout: 20],
        fn sink ->
          sink.(Event.durable(:blocked))
          sink.(Event.durable(:terminal))
          :result
        end
      )

    assert result == :result
    assert {:error, %{delivered: 1, errors: [:callback_timeout]}} = status
    assert_receive %Event{type: :terminal}
  end

  test "owner termination closes the observer and its in-flight callback" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, observer} =
          Observer.open(
            fn _ ->
              send(parent, {:worker, self()})
              Process.sleep(5000)
            end,
            callback_timeout: 1000
          )

        send(parent, {:observer, observer})
        Observer.push(observer, Event.durable(:one))
        receive do: (:finish -> :ok)
      end)

    assert_receive {:observer, observer}
    assert_receive {:worker, worker}
    monitor = Process.monitor(observer)
    worker_monitor = Process.monitor(worker)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
  end
end
