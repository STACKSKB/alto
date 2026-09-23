defmodule Alto.ProtocolTest do
  use ExUnit.Case, async: true

  alias Alto.Approval.Request, as: ApprovalRequest
  alias Alto.Event
  alias Alto.Protocol

  @max_line_bytes 1_048_576

  defp decode_line(line) do
    line
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
    |> JSON.decode!()
  end

  describe "term encoding" do
    test "tuples become tagged arrays and opaque terms become bounded inspect strings" do
      assert Protocol.encode_term({:denied, :user}) == %{"$tuple" => ["denied", "user"]}

      inspect_value = Protocol.encode_term(self())
      assert %{"$inspect" => text} = inspect_value
      assert text =~ "#PID<"
      assert byte_size(text) <= 1_100
    end

    test "diagnostic keys are bounded UTF-8 even across four-byte characters" do
      encoded = Protocol.encode_term(%{[String.duplicate("🙂", 400)] => "value"})
      [key] = Map.keys(encoded)
      assert String.valid?(key)
      assert byte_size(key) <= 1_000
      assert String.ends_with?(key, "…")
    end

    test "inspect fallback is a string and improper lists do not crash the encoder" do
      assert Protocol.encode_term([1 | 2]) == [1, 2]

      assert %{"$inspect" => text} = Protocol.encode_term(fn -> :ok end)
      assert text =~ "#Function<"
    end
  end

  describe "server-to-client encoding" do
    test "durable events carry a seq, live events carry null" do
      durable = Event.durable(:tool_completed, %{call_id: "call-1", name: "echo"})
      live = Event.live(:model_delta, %{text: "he"})

      assert {:ok, line} = Protocol.event("s-2", "run-41", 7, durable, @max_line_bytes)

      assert %{
               "type" => "event",
               "id" => "s-2",
               "run_id" => "run-41",
               "seq" => 7,
               "domain" => "durable",
               "at_ms" => at_ms,
               "event" => %{
                 "type" => "tool_completed",
                 "data" => %{"call_id" => "call-1", "name" => "echo"}
               }
             } = decode_line(line)

      assert is_integer(at_ms)

      assert {:ok, line} = Protocol.event("s-3", "run-41", nil, live, @max_line_bytes)
      assert %{"seq" => nil, "domain" => "live"} = envelope = decode_line(line)
      assert envelope["event"]["type"] == "model_delta"
    end

    test "attached nests the replayed durable event envelopes" do
      replay = [
        {1, Event.durable(:model_completed, %{message: "hi", tool_calls: []})},
        {2, Event.durable(:step_settled, %{step: 1, outcome: :completed})}
      ]

      assert {:ok, line} = Protocol.attached("c-3", "run-41", false, 2, replay, @max_line_bytes)

      assert %{
               "type" => "attached",
               "id" => "c-3",
               "run_id" => "run-41",
               "gap" => false,
               "head_seq" => 2,
               "events" => [
                 %{"seq" => 1, "event" => %{"type" => "model_completed"}},
                 %{"seq" => 2, "event" => %{"type" => "step_settled"}}
               ]
             } = decode_line(line)
    end

    test "approval messages encode the display-safe request" do
      request = %ApprovalRequest{
        id: "run-41:op-1",
        run_id: "run-41",
        call_id: "call-1",
        tool: "run_command",
        arguments: %{"program" => "ls"},
        execution_mode: :exclusive,
        details: %{backend: :unsandboxed, isolation: :none}
      }

      assert {:ok, line} = Protocol.approval_request("s-5", "run-41", request, @max_line_bytes)

      assert %{
               "type" => "approval_request",
               "request" => %{
                 "id" => "run-41:op-1",
                 "run_id" => "run-41",
                 "call_id" => "call-1",
                 "tool" => "run_command",
                 "arguments" => %{"program" => "ls"},
                 "execution_mode" => "exclusive",
                 "details" => %{"backend" => "unsandboxed", "isolation" => "none"}
               }
             } = decode_line(line)

      assert {:ok, line} =
               Protocol.approval_resolved(
                 "s-6",
                 "run-41",
                 request,
                 {:denied, :user},
                 @max_line_bytes
               )

      assert %{"type" => "approval_resolved", "decision" => %{"$tuple" => ["denied", "user"]}} =
               decode_line(line)
    end

    test "result covers all three outcomes and omits a nil output" do
      assert {:ok, line} = Protocol.result("s-9", "run-41", :ok, "finished", 3, @max_line_bytes)

      assert decode_line(line) == %{
               "v" => 1,
               "type" => "result",
               "id" => "s-9",
               "run_id" => "run-41",
               "outcome" => "ok",
               "output" => "finished",
               "model_requests" => 3
             }

      assert {:ok, line} =
               Protocol.result("s-10", "run-41", {:error, :loop_stalled}, nil, 1, @max_line_bytes)

      envelope = decode_line(line)
      assert envelope["outcome"] == "error"
      assert envelope["reason"] == "loop_stalled"
      refute Map.has_key?(envelope, "output")

      assert {:ok, line} =
               Protocol.result("s-11", "run-41", {:cancelled, :user}, nil, 2, @max_line_bytes)

      assert %{"outcome" => "cancelled", "reason" => "user"} = decode_line(line)
    end

    test "error envelopes can omit a client id" do
      assert {:ok, line} = Protocol.error(nil, "invalid", "no id", @max_line_bytes)
      assert %{"id" => nil} = decode_line(line)
    end

    test "an envelope over the line bound overflows instead of truncating" do
      big = Event.durable(:tool_completed, %{output: String.duplicate("x", 2_000_000)})

      assert {:error, :overflow} = Protocol.event("s-2", "run-41", 1, big, @max_line_bytes)
    end
  end

  describe "client-to-server decoding" do
    test "attach accepts full, minimal, and filtered forms" do
      full =
        JSON.encode!(%{
          "v" => 1,
          "type" => "attach",
          "id" => "c-3",
          "run_id" => "run-41",
          "from_seq" => 4,
          "domains" => ["durable"]
        })

      assert {:ok, {:attach, "c-3", "run-41", 4, [:durable]}} = Protocol.decode_command(full)

      minimal = JSON.encode!(%{"v" => 1, "type" => "attach", "id" => "c-3"})

      assert {:ok, {:attach, "c-3", nil, 1, [:durable, :live]}} = Protocol.decode_command(minimal)

      bad = JSON.encode!(%{"v" => 1, "type" => "attach", "id" => "c-3", "domains" => ["nope"]})
      assert {:error, :invalid} = Protocol.decode_command(bad)
    end

    test "start_run requires config and task and rejects overrides" do
      good =
        JSON.encode!(%{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-5",
          "config" => "my-alto-config",
          "task" => "Explain this repository"
        })

      assert {:ok, {:start_run, "c-5", "my-alto-config", "Explain this repository", nil}} =
               Protocol.decode_command(good)

      resuming =
        JSON.encode!(%{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-5",
          "config" => "my-alto-config",
          "task" => "Follow up",
          "resume" => "sess-abc123"
        })

      assert {:ok, {:start_run, "c-5", "my-alto-config", "Follow up", "sess-abc123"}} =
               Protocol.decode_command(resuming)

      overrides =
        JSON.encode!(%{
          "v" => 1,
          "type" => "start_run",
          "id" => "c-5",
          "config" => "c",
          "task" => "t",
          "overrides" => %{}
        })

      assert {:error, :unsupported} = Protocol.decode_command(overrides)

      missing =
        JSON.encode!(%{"v" => 1, "type" => "start_run", "id" => "c-5", "config" => "c"})

      assert {:error, :invalid} = Protocol.decode_command(missing)
    end

    test "session_transcript decodes with only a session id" do
      line =
        JSON.encode!(%{
          "v" => 1,
          "type" => "session_transcript",
          "id" => "c-9",
          "session_id" => "sess-1"
        })

      assert {:ok, {:session_transcript, "c-9", "sess-1"}} = Protocol.decode_command(line)

      for key <- ["limit", "cursor"] do
        rejected = line |> JSON.decode!() |> Map.put(key, nil) |> JSON.encode!()
        assert Protocol.decode_command(rejected) == {:error, :unsupported}
      end
    end

    test "cancel requires a run id and carries an optional reason" do
      good = JSON.encode!(%{"v" => 1, "type" => "cancel", "id" => "c-6", "run_id" => "run-41"})

      assert {:ok, {:cancel, "c-6", "run-41", nil}} = Protocol.decode_command(good)

      with_reason =
        JSON.encode!(%{
          "v" => 1,
          "type" => "cancel",
          "id" => "c-6",
          "run_id" => "run-41",
          "reason" => "operator_stop"
        })

      assert {:ok, {:cancel, "c-6", "run-41", "operator_stop"}} =
               Protocol.decode_command(with_reason)

      assert {:error, :invalid} =
               Protocol.decode_command(
                 JSON.encode!(%{"v" => 1, "type" => "cancel", "id" => "c-6"})
               )
    end

    test "approval_response decodes approve and deny decisions" do
      approve =
        JSON.encode!(%{
          "v" => 1,
          "type" => "approval_response",
          "id" => "c-7",
          "request_id" => "call-1",
          "decision" => "approve"
        })

      assert {:ok, {:approval_response, "c-7", "call-1", :approve}} =
               Protocol.decode_command(approve)

      deny =
        JSON.encode!(%{
          "v" => 1,
          "type" => "approval_response",
          "id" => "c-8",
          "request_id" => "call-1",
          "decision" => %{"deny" => "not today"}
        })

      assert {:ok, {:approval_response, "c-8", "call-1", {:deny, "not today"}}} =
               Protocol.decode_command(deny)
    end

    test "queue commands decode with bounded counts and required claim ids" do
      minimal = JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-10"})
      assert {:ok, {:queue_claim, "c-10", 1, nil}} = Protocol.decode_command(minimal)

      full =
        JSON.encode!(%{
          "v" => 1,
          "type" => "queue_claim",
          "id" => "c-11",
          "count" => 5,
          "by" => "station-1"
        })

      assert {:ok, {:queue_claim, "c-11", 5, "station-1"}} = Protocol.decode_command(full)

      bad_count = JSON.encode!(%{"v" => 1, "type" => "queue_claim", "id" => "c-12", "count" => 0})
      assert {:error, :invalid} = Protocol.decode_command(bad_count)

      ack =
        JSON.encode!(%{"v" => 1, "type" => "queue_ack", "id" => "c-13", "claim_id" => "clm-1"})

      assert {:ok, {:queue_ack, "c-13", "clm-1"}} = Protocol.decode_command(ack)

      ack_missing = JSON.encode!(%{"v" => 1, "type" => "queue_ack", "id" => "c-14"})
      assert {:error, :invalid} = Protocol.decode_command(ack_missing)

      release =
        JSON.encode!(%{
          "v" => 1,
          "type" => "queue_release",
          "id" => "c-15",
          "claim_id" => "clm-1"
        })

      assert {:ok, {:queue_release, "c-15", "clm-1"}} = Protocol.decode_command(release)
    end

    test "command payloads stay maps and malformed required fields fail decoding" do
      envelope = %{
        "v" => 1,
        "id" => "client",
        "type" => "command",
        "name" => "inspect",
        "payload" => %{"query" => [1, 2]}
      }

      assert {:ok, {:command, "client", "inspect", %{"query" => [1, 2]}}} =
               Protocol.decode_command(JSON.encode!(envelope))

      for fields <- [
            %{"type" => "command", "name" => "inspect", "payload" => []},
            %{"type" => "command", "name" => "", "payload" => %{}},
            %{
              "type" => "approval_response",
              "request_id" => "request",
              "decision" => %{"deny" => 0}
            },
            %{"type" => "approval_response", "request_id" => "", "decision" => "approve"},
            %{"type" => "start_run", "config" => "config", "task" => "task", "resume" => 7}
          ] do
        line = JSON.encode!(Map.merge(%{"v" => 1, "id" => "client"}, fields))
        assert Protocol.decode_command(line) == {:error, :invalid}
      end
    end

    test "reserved types decode for the listener to reject explicitly" do
      auth = JSON.encode!(%{"v" => 1, "type" => "auth", "id" => "c-1", "token" => "t"})
      assert {:ok, {:auth, "c-1", %{"token" => "t"}}} = Protocol.decode_command(auth)

      input = JSON.encode!(%{"v" => 1, "type" => "input", "id" => "c-2", "payload" => %{}})
      assert {:ok, {:input, "c-2", %{"payload" => %{}}}} = Protocol.decode_command(input)
    end

    test "unknown types, bad versions, and malformed JSON decode to bounded errors" do
      unknown = JSON.encode!(%{"v" => 1, "type" => "ping", "id" => "c-1"})
      assert {:error, {:unknown_type, "c-1"}} = Protocol.decode_command(unknown)

      wrong_version = JSON.encode!(%{"v" => 2, "type" => "attach", "id" => "c-1"})
      assert {:error, :invalid} = Protocol.decode_command(wrong_version)

      assert {:error, :invalid} = Protocol.decode_command("not json at all")

      no_id = JSON.encode!(%{"v" => 1, "type" => "attach"})
      assert {:error, :invalid} = Protocol.decode_command(no_id)
    end
  end
end
