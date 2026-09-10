defmodule Alto.StorageCrossVMTest do
  use ExUnit.Case, async: false

  @owner_source Path.expand("test/support/storage_cross_vm_owner.ex")

  alias Alto.Credentials
  alias Alto.Queue
  alias Alto.Session

  setup do
    unless Node.alive?() do
      {:ok, _pid} =
        Node.start(String.to_atom("alto_test_#{System.unique_integer()}"), :shortnames)
    end

    root = Path.join(System.tmp_dir!(), "alto-cross-vm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "independent VMs append sessions without losing records", %{root: root} do
    {:ok, id} = Session.create("cross-vm", %{}, session_dir: root)
    peers = [peer!(), peer!()]
    on_exit(fn -> Enum.each(peers, &stop_peer/1) end)

    peers
    |> Enum.with_index()
    |> Enum.map(fn {{_pid, node}, worker} ->
      Task.async(fn ->
        Enum.each(1..20, fn index ->
          record = %{"type" => "event", "worker" => worker, "index" => index}

          assert :ok =
                   :rpc.call(node, Session, :append, [id, record, [session_dir: root]], 10_000)
        end)
      end)
    end)
    |> Enum.each(&Task.await(&1, 30_000))

    assert {:ok, records} = Session.read(id, session_dir: root)
    assert length(records) == 41
  end

  test "stale credential snapshots merge across independent VMs", %{root: root} do
    path = Path.join(root, "credentials.json")
    peers = [peer!(), peer!()]
    on_exit(fn -> Enum.each(peers, &stop_peer/1) end)
    [{_pid_a, node_a}, {_pid_b, node_b}] = peers

    assert {:ok, credentials_a} = :rpc.call(node_a, Credentials, :load, [path])
    assert {:ok, credentials_b} = :rpc.call(node_b, Credentials, :load, [path])

    [
      {node_a, %{"api_key" => "from-a"}},
      {node_b, %{"model" => "from-b"}}
    ]
    |> Enum.map(fn {node, values} ->
      Task.async(fn ->
        credentials = if values["api_key"], do: credentials_a, else: credentials_b
        :rpc.call(node, Credentials, :put, [credentials, "provider", values], 10_000)
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
    |> Enum.each(fn {:ok, _credentials} -> :ok end)

    assert {:ok, loaded} = Credentials.load(path)
    assert Credentials.get(loaded, "provider", "api_key") == "from-a"
    assert Credentials.get(loaded, "provider", "model") == "from-b"
  end

  test "queue lifetime ownership blocks another VM and recovers after owner death", %{root: root} do
    id = "cross-queue"
    owner = peer!()
    contender = peer!()

    on_exit(fn ->
      stop_peer(owner)
      stop_peer(contender)
    end)

    {_owner_pid, owner_node} = owner
    {_contender_pid, contender_node} = contender

    owner_process =
      :rpc.call(owner_node, :erlang, :spawn, [
        Alto.StorageCrossVMOwner,
        :hold_queue,
        [[id: id, dir: root, name: nil]]
      ])

    Process.sleep(100)
    assert :rpc.call(owner_node, Process, :alive?, [owner_process])

    assert {:error, :timeout} =
             :rpc.call(
               contender_node,
               Queue,
               :start_link,
               [[id: id, dir: root, name: nil, lock_timeout: 100]],
               10_000
             )

    :peer.stop(elem(owner, 0))
    Process.sleep(100)

    assert {:ok, _queue_pid} =
             :rpc.call(
               contender_node,
               Queue,
               :start_link,
               [[id: id, dir: root, name: nil, lock_timeout: 1_000]],
               10_000
             )
  end

  test "safe term decoding accepts native terms in a fresh VM and rejects bad ETF data" do
    compressed = :erlang.term_to_binary(String.duplicate("x", 100_000), compressed: 9)
    trailing = :erlang.term_to_binary(:ok) <> <<0>>

    assert {:error, _reason} = Session.decode_term(%{"$term" => Base.encode64(compressed)})
    assert {:error, _reason} = Session.decode_term(%{"$term" => Base.encode64(trailing)})

    payload = Session.encode_term(%{status: :approved, uri: %URI{scheme: "https"}})
    peer = peer!()
    {_pid, node} = peer

    on_exit(fn -> stop_peer(peer) end)

    assert {:module, URI} = :rpc.call(node, Code, :ensure_loaded, [URI])

    assert {:ok, %{status: :approved, uri: %URI{scheme: "https"}}} =
             :rpc.call(node, Session, :decode_term, [payload])

    unknown = Session.encode_term(:alto_cross_vm_unknown_atom_12345)
    assert {:error, _reason} = :rpc.call(node, Session, :decode_term, [unknown])
  end

  defp peer! do
    args = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    {:ok, pid, node} =
      :peer.start_link(%{
        name: String.to_atom("alto_peer_#{System.unique_integer()}"),
        args: args
      })

    {module, binary} =
      case Process.get(:alto_storage_owner_beam) do
        nil ->
          compiler_options = Code.compiler_options()
          Code.compiler_options(ignore_module_conflict: true)
          [{module, binary}] = Code.compile_file(@owner_source)
          Code.compiler_options(compiler_options)
          Process.put(:alto_storage_owner_beam, {module, binary})
          {module, binary}

        {module, binary} ->
          {module, binary}
      end

    {:module, ^module} =
      :rpc.call(node, :code, :load_binary, [module, String.to_charlist(@owner_source), binary])

    {pid, node}
  end

  defp stop_peer({pid, _node}) do
    if Process.alive?(pid), do: :peer.stop(pid)
  catch
    _, _ -> :ok
  end
end
