defmodule Alto.Listeners.WebhookTest do
  @moduledoc """
  The webhook ingress: HMAC verification before trust, bounded bodies,
  delivery-id dedup with release-on-failed-start, and one short rule run
  per accepted delivery (the integration contract job-flow ingress).
  """

  use ExUnit.Case, async: true

  alias Alto.FrontEnd.Registry
  alias Alto.Ingress.HMAC
  alias Alto.Ingress.IdentityHeader
  alias Alto.Listeners.Webhook

  @secret "event-webhook-secret"

  defmodule TaskTool do
    @behaviour Alto.Tool

    @impl true
    def name, do: :task_tool

    @impl true
    def schema, do: %{parameters: %{type: "object", properties: %{}}}

    @impl true
    def execution_mode, do: :parallel

    @impl true
    def approval, do: :never

    @impl true
    def run(arguments, _context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:rule_ran, arguments})
      {:ok, arguments}
    end
  end

  defmodule RecordingInbox do
    @behaviour Alto.Inbox

    @impl true
    def admit(delivery_key, payload, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:inbox_admitted, delivery_key, payload})
      Keyword.get(opts, :result, {:ok, :stored})
    end
  end

  defmodule InvalidResultInbox do
    @behaviour Alto.Inbox

    @impl true
    def admit(_delivery_key, _payload, _opts), do: :accepted
  end

  defmodule ValidatingInbox do
    @behaviour Alto.Inbox

    @impl true
    def validate_options(opts) do
      if Keyword.has_key?(opts, :required), do: :ok, else: {:error, :missing_required_option}
    end

    @impl true
    def admit(_delivery_key, _payload, _opts), do: {:ok, :stored}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "alto-webhook-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    registry = :"webhook-registry-#{System.unique_integer([:positive])}"
    listener = :"webhook-listener-#{System.unique_integer([:positive])}"
    parent = self()

    resolver = fn
      "job" ->
        {:ok, [loop: Alto.rule_loop(steps: ["task_tool"]), tools: [{TaskTool, test_pid: parent}]]}

      "broken" ->
        {:error, {:unknown_config, "broken"}}

      other ->
        {:error, {:unknown_config, other}}
    end

    start_supervised!({Registry, name: registry, config_resolver: resolver, cwd: root})

    %{
      registry: registry,
      listener: listener,
      root: root,
      registry_name: registry
    }
  end

  defp start_listener(listener, registry, endpoints) do
    start_supervised!(
      {Webhook, registry: registry, port: 0, endpoints: endpoints, name: listener}
    )

    Webhook.bound_port(listener)
  end

  defp endpoint(config_name) do
    %{
      path: "/hooks/events",
      verify: {:hmac_sha256_base64, @secret},
      on_event: {:start_run, config_name}
    }
  end

  defp signature(body, secret \\ @secret) do
    Base.encode64(:crypto.mac(:hmac, :sha256, secret, body))
  end

  test "generic ingress verification accepts configured base64 and identity headers" do
    body = ~s({"event":"created"})
    secret = "generic-secret"
    digest = Base.encode64(:crypto.mac(:hmac, :sha256, secret, body))
    headers = [{"X-Signature", "v1=" <> digest}, {"X-Delivery-Id", "generic-1"}]

    assert :ok =
             HMAC.verify(body, headers,
               secret: secret,
               header: "x-signature",
               encoding: :base64,
               prefix: "v1="
             )

    assert {:ok, "generic-1"} = IdentityHeader.extract(headers, header: "x-delivery-id")
  end

  test "GitHub-style ingress verification accepts prefixed lowercase hex signatures" do
    body = "{\"action\":\"push\"}"
    secret = "github-secret"
    digest = Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
    headers = [{"X-Hub-Signature-256", "sha256=" <> digest}, {"X-GitHub-Delivery", "gh-1"}]

    assert :ok =
             HMAC.verify(body, headers,
               secret: secret,
               header: "x-hub-signature-256",
               encoding: :hex,
               prefix: "sha256="
             )

    assert {:ok, "gh-1"} = IdentityHeader.extract(headers, header: "x-github-delivery")
  end

  test "identity extraction rejects duplicate delivery headers" do
    assert {:error, :duplicate_delivery_id} =
             IdentityHeader.extract(
               [{"x-delivery-id", "one"}, {"X-Delivery-Id", "two"}],
               header: "x-delivery-id"
             )
  end

  defp post(port, path, body, headers) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    header_lines =
      headers
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\r\n")

    request =
      "POST #{path} HTTP/1.1\r\nHost: x\r\n#{header_lines}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    response
  end

  defp post_chunked(port, path, body, headers) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    header_lines =
      headers
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\r\n")

    chunked_body =
      Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n0\r\n\r\n"

    request =
      "POST #{path} HTTP/1.1\r\nHost: x\r\n#{header_lines}\r\n" <>
        "Transfer-Encoding: chunked\r\n\r\n" <> chunked_body

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    response
  end

  defp post_event(port, opts) do
    body = Keyword.get(opts, :body, ~s({"id": 1, "total": "10.00"}))
    delivery_id = Keyword.get(opts, :delivery_id, "del-1")
    sig = Keyword.get(opts, :signature, signature(body))

    headers =
      [
        {"X-Signature", sig},
        {"X-Delivery-ID", delivery_id}
      ] ++ Keyword.get(opts, :extra_headers, [])

    post(port, Keyword.get(opts, :path, "/hooks/events"), body, headers)
  end

  test "a verified delivery starts a run with the body as the task", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])

    response = post_event(port, delivery_id: "del-ok")
    assert response =~ "200 OK"

    assert_receive {:rule_ran, %{"id" => 1, "total" => "10.00"}}, 2_000
  end

  test "a wrong or missing signature is rejected before anything runs", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])

    assert post_event(port, delivery_id: "del-bad-sig", signature: signature("other body")) =~
             "401"

    assert post_event(port,
             delivery_id: "del-no-sig",
             extra_headers: [{"X-Signature", ""}]
           ) =~ "401"

    # The delivery-id claim happened after verification only; nothing started.
    refute_received {:rule_ran, _}

    # And a correct delivery for those ids still works (nothing was recorded).
    response = post_event(port, delivery_id: "del-bad-sig")
    assert response =~ "200 OK"
    assert_receive {:rule_ran, _}, 2_000
  end

  test "a redelivered delivery id answers 200 and starts nothing", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])

    assert post_event(port, delivery_id: "del-dup") =~ "200 OK"
    assert_receive {:rule_ran, _}, 2_000

    assert post_event(port, delivery_id: "del-dup") =~ "200 OK"
    assert post_event(port, delivery_id: "del-dup") =~ "200 OK"
    refute_received {:rule_ran, _}
  end

  test "a failed run start answers 5xx and releases the id for retry", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("broken")])

    assert post_event(port, delivery_id: "del-fail") =~ "500"
    # The id was released, so the sender's retry is not swallowed as duplicate.
    assert post_event(port, delivery_id: "del-fail") =~ "500"
  end

  test "oversized bodies are rejected, never truncated", %{
    listener: listener,
    registry: registry
  } do
    port =
      start_listener(listener, registry, [Map.put(endpoint("job"), :max_body_bytes, 16)])

    assert post_event(port, body: String.duplicate("x", 64)) =~ "413"
    refute_received {:rule_ran, _}
  end

  test "chunked bodies are read to the endpoint bound before verification", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])
    body = ~s({"id": 9})

    headers = [
      {"X-Signature", signature(body)},
      {"X-Delivery-ID", "chunked-1"}
    ]

    assert post_chunked(port, "/hooks/events", body, headers) =~ "200 OK"
    assert_receive {:rule_ran, %{"id" => 9}}, 2_000
  end

  test "missing delivery id and bad lengths are bad requests", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])

    assert post_event(port, extra_headers: [{"X-Delivery-ID", ""}]) =~ "400"
    assert post_event(port, delivery_id: String.duplicate("d", 201)) =~ "400"
    refute_received {:rule_ran, _}

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    :ok =
      :gen_tcp.send(
        socket,
        "POST /hooks/events HTTP/1.1\r\nHost: x\r\nContent-Length: not-a-number\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "400"
  end

  test "unknown paths and methods are rejected without parsing bodies", %{
    listener: listener,
    registry: registry
  } do
    port = start_listener(listener, registry, [endpoint("job")])

    body = ~s({"id": 1})
    headers = [{"X-Signature", signature(body)}, {"X-Delivery-ID", "d"}]

    assert post(port, "/hooks/other", body, headers) =~ "404"

    # A content length beyond the endpoint bound is a 413 before the body
    # is read, so the claimed length is never trusted as allocation.
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    :ok =
      :gen_tcp.send(
        socket,
        "POST /hooks/events HTTP/1.1\r\nHost: x\r\nX-Signature: #{signature("")}\r\n" <>
          "X-Delivery-ID: d\r\nContent-Length: 999999999\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "413"

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

    :ok =
      :gen_tcp.send(
        socket,
        "GET /hooks/events HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"
      )

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "405"
  end

  test "invalid endpoint configuration fails the listener closed" do
    registry = :"webhook-registry-#{System.unique_integer([:positive])}"

    for bad <- [
          [%{path: "/x", on_event: {:start_run, "job"}}],
          [%{path: "/x", verify: :none, on_event: {:start_run, "job"}}],
          [
            %{
              path: "no-slash",
              verify: {:hmac_sha256_base64, @secret},
              on_event: {:start_run, "job"}
            }
          ],
          [%{path: "/x", verify: {:hmac_sha256_base64, @secret}, on_event: :reboot}],
          [%{path: "/x", verify: {:hmac_sha256_base64, @secret}, on_event: {:enqueue, nil}}],
          [%{path: "/x", verify: {:hmac_sha256_base64, @secret}, on_event: {:enqueue, 42}}],
          [
            %{
              path: "/x",
              verify: {:hmac_sha256_base64, @secret},
              on_event: {:enqueue, {String, []}}
            }
          ],
          [
            %{
              path: "/x",
              verify: {:hmac_sha256_base64, @secret},
              on_event: {:enqueue, {ValidatingInbox, []}}
            }
          ]
        ] do
      name = :"bad-webhook-#{System.unique_integer([:positive])}"

      assert {:error, {{:webhook_listener_failed, _reason}, _spec}} =
               start_supervised(
                 {Webhook, registry: registry, port: 0, endpoints: bad, name: name}
               )
    end
  end

  test "duplicate endpoint paths fail closed" do
    registry = :"webhook-registry-#{System.unique_integer([:positive])}"
    endpoint = endpoint("job")
    name = :"duplicate-webhook-#{System.unique_integer([:positive])}"

    assert {:error,
            {{:webhook_listener_failed, {:duplicate_endpoint_path, "/hooks/events"}}, _spec}} =
             start_supervised(
               {Webhook, registry: registry, port: 0, endpoints: [endpoint, endpoint], name: name}
             )
  end

  describe "enqueue mode (durable inbox, alto.exs decides)" do
    defp start_inbox!(opts \\ []) do
      dir =
        Path.join(System.tmp_dir!(), "alto-webhook-inbox-#{System.unique_integer([:positive])}")

      name = :"webhook-inbox-#{System.unique_integer([:positive])}"
      id = "inbox#{System.unique_integer([:positive])}"
      {:ok, _} = Alto.Queue.start_link(Keyword.merge([id: id, dir: dir, name: name], opts))
      on_exit(fn -> File.rm_rf!(dir) end)
      name
    end

    defp enqueue_endpoint(queue) do
      %{
        path: "/hooks/events",
        verify: {:hmac_sha256_base64, @secret},
        on_event: {:enqueue, queue}
      }
    end

    test "alto.exs can select an external inbox backend without changing the listener", %{
      listener: listener,
      registry: registry
    } do
      endpoint = %{
        path: "/hooks/events",
        verify: {:hmac_sha256_base64, @secret},
        on_event: {:enqueue, {RecordingInbox, test_pid: self()}}
      }

      port = start_listener(listener, registry, [endpoint])
      body = ~s({"id": 8})

      assert post_event(port, body: body, delivery_id: "external-1") =~ "200 OK"

      assert_receive {:inbox_admitted, "/hooks/events:external-1",
                      %{"delivery_id" => "external-1", "body" => ^body}}
    end

    test "an invalid backend reply fails as a retryable server error", %{
      listener: listener,
      registry: registry
    } do
      endpoint = %{
        path: "/hooks/events",
        verify: {:hmac_sha256_base64, @secret},
        on_event: {:enqueue, {InvalidResultInbox, []}}
      }

      port = start_listener(listener, registry, [endpoint])
      assert post_event(port, delivery_id: "invalid-reply") =~ "500"
    end

    test "a verified delivery is persisted before 200; redelivery dedups", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      body = ~s({"id": 7, "total": "40.00"})
      assert post_event(port, body: body, delivery_id: "inbox-del-1") =~ "200 OK"

      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)

      assert [
               %{
                 key: "/hooks/events:inbox-del-1",
                 payload: %{"delivery_id" => "inbox-del-1", "body" => ^body}
               }
             ] =
               Alto.Queue.records(queue)

      # The sender's retry is a durable no-op, still 200.
      assert post_event(port, body: body, delivery_id: "inbox-del-1") =~ "200 OK"
      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)

      # And the record is claimable work: input >= inbox >> 200 -> Claim -> Ack.
      assert {:ok, [claimed]} = Alto.Queue.claim(queue, 1, "station-1")
      assert claimed.key == "/hooks/events:inbox-del-1"
      assert :ok = Alto.Queue.ack(queue, claimed.claim_id)
      assert %{pending: 0, claimed: 0} = Alto.Queue.count(queue)
    end

    test "a claimed key answers 200 duplicate instead of failing the sender", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      assert post_event(port, delivery_id: "inbox-busy") =~ "200 OK"
      assert {:ok, [_claimed]} = Alto.Queue.claim(queue, 1, "station-1")

      # Someone is actively job it: still 200, never a 500 the sender
      # would (correctly) retry into a duplicate print.
      assert post_event(port, delivery_id: "inbox-busy") =~ "200 OK"
      assert %{pending: 0, claimed: 1} = Alto.Queue.count(queue)
    end

    test "a full inbox answers 503 so the sender retries; nothing is lost", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!(max_records: 1)
      {:ok, _} = Alto.Queue.put(queue, "filler", %{n: 1})
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      assert post_event(port, delivery_id: "inbox-overflow") =~ "503"
      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)
      assert [%{key: "filler"}] = Alto.Queue.records(queue)
    end

    test "an oversized inbox payload is rejected, never truncated", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!(max_payload_bytes: 10)
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      assert post_event(port, delivery_id: "inbox-big") =~ "413"
      assert %{pending: 0} = Alto.Queue.count(queue)
    end

    test "an unreachable inbox fails closed with 500 so the sender retries", %{
      listener: listener,
      registry: registry
    } do
      dead = :"webhook-dead-queue-#{System.unique_integer([:positive])}"
      port = start_listener(listener, registry, [enqueue_endpoint(dead)])

      assert post_event(port, delivery_id: "inbox-dead") =~ "500"
    end

    test "the same delivery id on two endpoints never collides", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()

      endpoints = [
        %{path: "/hooks/a", verify: {:hmac_sha256_base64, @secret}, on_event: {:enqueue, queue}},
        %{path: "/hooks/b", verify: {:hmac_sha256_base64, @secret}, on_event: {:enqueue, queue}}
      ]

      port = start_listener(listener, registry, endpoints)
      body = ~s({"id": 1})

      assert post(port, "/hooks/a", body, signed_headers(body, "shared-del")) =~ "200 OK"
      assert post(port, "/hooks/b", body, signed_headers(body, "shared-del")) =~ "200 OK"

      assert %{pending: 2} = Alto.Queue.count(queue)

      keys = queue |> Alto.Queue.records() |> Enum.map(& &1.key) |> Enum.sort()
      assert keys == ["/hooks/a:shared-del", "/hooks/b:shared-del"]
    end

    test "parallel posts for one delivery admit exactly one record", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])
      body = ~s({"id": 2})

      responses =
        1..20
        |> Task.async_stream(
          fn _ -> post(port, "/hooks/events", body, signed_headers(body, "race")) end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, response} -> response end)

      assert Enum.all?(responses, &(&1 =~ "200 OK"))
      assert %{pending: 1, claimed: 0} = Alto.Queue.count(queue)
    end

    test "ack then restart: the redelivery is still a duplicate", %{
      listener: listener,
      registry: registry
    } do
      dir =
        Path.join(System.tmp_dir!(), "alto-event-restart-#{System.unique_integer([:positive])}")

      id = "restart#{System.unique_integer([:positive])}"
      name = :"event-restart-queue-#{System.unique_integer([:positive])}"
      {:ok, pid} = Alto.Queue.start_link(id: id, dir: dir, name: name)
      on_exit(fn -> File.rm_rf!(dir) end)

      port = start_listener(listener, registry, [enqueue_endpoint(name)])
      body = ~s({"id": 3})

      assert post(port, "/hooks/events", body, signed_headers(body, "survive")) =~ "200 OK"
      assert {:ok, [claimed]} = Alto.Queue.claim(name, 1, "station-1")
      :ok = Alto.Queue.ack(name, claimed.claim_id)

      # Crash between commit and any later response: only the log survives.
      GenServer.stop(pid)
      {:ok, _} = Alto.Queue.start_link(id: id, dir: dir, name: name)

      assert post(port, "/hooks/events", body, signed_headers(body, "survive")) =~ "200 OK"
      assert %{pending: 0, claimed: 0} = Alto.Queue.count(name)
    end

    test "a conflicting redelivered body keeps the first bytes", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      first = ~s({"id": 4, "total": "10.00"})
      second = ~s({"id": 4, "total": "99.99"})

      assert post(port, "/hooks/events", first, signed_headers(first, "conflict")) =~ "200 OK"
      assert post(port, "/hooks/events", second, signed_headers(second, "conflict")) =~ "200 OK"

      assert [%{payload: %{"body" => ^first}}] = Alto.Queue.records(queue)
    end

    test "an overlong delivery id is rejected before storage", %{
      listener: listener,
      registry: registry
    } do
      queue = start_inbox!()
      port = start_listener(listener, registry, [enqueue_endpoint(queue)])

      assert post_event(port, delivery_id: String.duplicate("d", 201)) =~ "400"
      assert %{pending: 0} = Alto.Queue.count(queue)
    end

    defp signed_headers(body, delivery_id) do
      [
        {"X-Signature", signature(body)},
        {"X-Delivery-ID", delivery_id}
      ]
    end
  end
end
