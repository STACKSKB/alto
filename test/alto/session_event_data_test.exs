defmodule Alto.SessionEventDataTest do
  use ExUnit.Case, async: true
  alias Alto.{Session, Event, Protocol}

  test "one body retains typed keys, structs, tuples, and Unicode exactly" do
    data = %{
      text: String.duplicate("猫 café body\n", 500),
      map: %{:key => 1, "key" => 2, 42 => true},
      structure: %URI{scheme: "https", host: "example.test"},
      tuple: {:ok, [1, nil, false]},
      literal_tags: ["map", ["atom", "not_a_type"]],
      tuple_key: %{{:a, :b} => "value"}
    }

    record = Session.event_record("run", Event.durable(:model_completed, data))
    stored = record |> JSON.encode!() |> JSON.decode!()
    refute Map.has_key?(stored, "wire_data")
    assert {:ok, ^data} = Session.decode_term(stored["data"])
    assert {:ok, projected} = Session.event_data(stored)
    assert projected == Protocol.encode_term(data)
    assert length(:binary.matches(JSON.encode!(record), "body")) == 500
  end

  test "legacy exact-only and dual records still replay" do
    data = %{message: "legacy", kind: :tool}

    assert Session.event_data(%{"data" => Session.encode_term(data)}) ==
             {:ok, Protocol.encode_term(data)}

    assert Session.event_data(%{"wire_data" => %{"message" => "saved"}, "data" => %{}}) ==
             {:ok, %{"message" => "saved"}}
  end

  test "safe exact decoding rejects opaque functions and compressed ETF" do
    record =
      Session.event_record("run", Event.durable(:model_completed, %{callback: fn -> :ok end}))

    assert {:error, _} = Session.decode_term(record["data"])
    assert {:ok, %{"callback" => %{"$inspect" => _}}} = Session.event_data(record)

    compressed =
      :erlang.term_to_binary(String.duplicate("a", 1_000_000), [:compressed]) |> Base.encode64()

    assert {:error, _} =
             Session.decode_term(%{
               "$event_term" => 1,
               "value" => ["opaque", compressed, "display"]
             })
  end

  test "the event codec independently bounds decoding and portable projection" do
    alias Alto.Persistence.EventCodec
    encoded = EventCodec.encode(%{text: String.duplicate("a", 100)})
    assert {:error, :invalid_event_data} = EventCodec.decode(encoded, max_bytes: 10)
    assert {:error, :invalid_event_data} = EventCodec.project(encoded, max_bytes: 10)
    assert {:error, :invalid_event_data} = EventCodec.decode(%{"$event_term" => 99, "value" => 1})

    deep = Enum.reduce(1..66, "text", fn _, inner -> ["list", [inner]] end)
    envelope = %{"$event_term" => 1, "value" => deep}
    assert {:error, :invalid_event_data} = EventCodec.decode(envelope)
    assert {:error, :invalid_event_data} = EventCodec.project(envelope)

    unknown = %{
      "$event_term" => 1,
      "value" => ["atom", "event_atom_#{System.unique_integer([:positive])}"]
    }

    assert {:error, :invalid_event_data} = EventCodec.decode(unknown)
    assert {:ok, name} = EventCodec.project(unknown)
    assert name == unknown["value"] |> List.last()
  end

  test "binary payloads round trip without pretending they are UTF-8" do
    data = %{bytes: <<255, 0, 128>>}
    encoded = Alto.Persistence.EventCodec.encode(data) |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^data} = Session.decode_term(encoded)
  end
end
