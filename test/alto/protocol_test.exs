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
    test "scalars pass through and atoms become strings" do
      assert Protocol.encode_term("s") == "s"
      assert Protocol.encode_term(1) == 1
      assert Protocol.encode_term(1.5) == 1.5
      assert Protocol.encode_term(true) == true
      assert Protocol.encode_term(nil) == nil
      assert Protocol.encode_term(:approved) == "approved"
    end

    test "maps stringify keys and lists map over elements" do
      assert Protocol.encode_term(%{:tool => :echo, "raw" => 2, 3 => :x}) == %{
               "tool" => "echo",
               "raw" => 2,
               "3" => "x"
             }

      assert Protocol.encode_term([:a, 1, "b"]) == ["a", 1, "b"]
    end

    test "structs encode as their field maps" do
      request = %Alto.Approval.Request{
        id: "run-1:op-1",
        run_id: "run-1",
        call_id: "call-1",
        operation_id: "run-1:op-1",
        tool: "echo",
        arguments: %{"value" => "hello"},
        execution_mode: :parallel
      }

      assert Protocol.encode_term(request) == %{
               "id" => "run-1:op-1",
               "run_id" => "run-1",
               "call_id" => "call-1",
               "operation_id" => "run-1:op-1",
               "tool" => "echo",
               "arguments" => %{"value" => "hello"},
               "execution_mode" => "parallel",
               "details" => %{}
             }
    end

    test "tuples become tagged arrays and opaque terms become bounded inspect strings" do
      assert Protocol.encode_term({:denied, :user}) == %{"$tuple" => ["denied", "user"]}

      inspect_value = Protocol.encode_term(self())
      assert %{"$inspect" => text} = inspect_value
      assert text =~ "#PID<"
      assert byte_size(text) <= 1_100
    end

    test "inspect fallback is a string and improper lists do not crash the encoder" do
      assert Protocol.encode_term([1 | 2]) == [1, 2]

      assert %{"$inspect" => text} = Protocol.encode_term(fn -> :ok end)
      assert text =~ "#Function<"
      assert String.valid?(text)
    end
  end

  describe "server-to-client encoding" do
    test "hello announces version, runs, and the line bound" do
      assert {:ok, line} = Protocol.hello("s-1", ["run-41"], @max_line_bytes)

      assert decode_line(line) == %{
               "v" => 1,
               "type" => "hello",
               "id" => "s-1",
               "runs" => ["run-41"],
               "max_line_bytes" => @max_line_bytes
             }
    end

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
        operation_id: "run-41:op-1",
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
                 "operation_id" => "run-41:op-1",
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

    test "overflow and error carry their codes" do
      assert {:ok, line} = Protocol.overflow("s-11", "run-41", :durable, 9, @max_line_bytes)

      assert decode_line(line) == %{
               "v" => 1,
               "type" => "overflow",
               "id" => "s-11",
               "run_id" => "run-41",
               "domain" => "durable",
               "last_seq" => 9
             }

      assert {:ok, line} = Protocol.error("c-4", "unknown_type", "mumble", @max_line_bytes)

      assert %{"type" => "error", "id" => "c-4", "code" => "unknown_type", "detail" => "mumble"} =
               decode_line(line)

      assert {:ok, line} = Protocol.error(nil, "invalid", "no id", @max_line_bytes)
      assert %{"id" => nil} = decode_line(line)
    end

    test "ok replies carry their payload" do
      assert {:ok, line} = Protocol.ok("c-5", %{"run_id" => "run-42"}, @max_line_bytes)

      assert decode_line(line) == %{
               "v" => 1,
               "type" => "ok",
               "id" => "c-5",
               "run_id" => "run-42"
             }
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

    test "sessions decodes with no payload" do
      line = JSON.encode!(%{"v" => 1, "type" => "sessions", "id" => "c-9"})

      assert {:ok, {:sessions, "c-9"}} = Protocol.decode_command(line)
    end

    test "session_events decodes bounded replay parameters" do
      line =
        JSON.encode!(%{
          "v" => 1,
          "type" => "session_events",
          "id" => "c-10",
          "session_id" => "sess-1",
          "limit" => 20,
          "cursor" => 3,
          "run_id" => "run-1"
        })

      assert {:ok, {:session_events, "c-10", "sess-1", 20, 3, "run-1"}} =
               Protocol.decode_command(line)
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
