# mix run scripts/conversation_storage_bench.exs SESSION_ID [SESSION_ID ...]
# Copies saved revisions into a temporary directory; original sessions are read only.
alias Alto.Session.Conversation
alias Alto.Session.Conversation.Store
source = Alto.Session.dir([])

measurements =
  Enum.map(System.argv(), fn id ->
    :ok = Alto.Session.validate_id(id)
    dir = Path.join(System.tmp_dir!(), "alto-storage-bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "conversations"))

    try do
      File.cp!(
        Path.join(source, id <> ".transcript.json"),
        Path.join(dir, id <> ".transcript.json")
      )

      File.cp_r!(Path.join([source, "conversations", id]), Path.join([dir, "conversations", id]))
      opts = [session_dir: dir]
      {:ok, paths} = Store.revision_files(id, opts)
      head_path = Path.join(dir, id <> ".transcript.json")

      checks =
        Enum.map([head_path | paths], fn path ->
          record = JSON.decode!(File.read!(path))
          {record["revision"], :crypto.hash(:sha256, JSON.encode!(record["messages"]))}
        end)

      before_head = JSON.decode!(File.read!(head_path))
      {:ok, before_bytes} = Store.disk_bytes(id, opts)
      before_bytes = before_bytes + File.stat!(head_path).size
      {us, {:ok, after_head}} = :timer.tc(fn -> Conversation.compact(id, opts) end)

      Enum.each(checks, fn {revision, hash} ->
        {:ok, record} = Conversation.fetch(id, revision, opts)
        ^hash = :crypto.hash(:sha256, JSON.encode!(record["messages"]))
      end)

      true = before_head["dispatch"] == after_head["dispatch"]
      {:ok, after_bytes} = Store.disk_bytes(id, opts)
      after_bytes = after_bytes + File.stat!(head_path).size

      %{
        session_id: id,
        revisions: length(checks),
        before_bytes: before_bytes,
        after_bytes: after_bytes,
        conversion_ms: div(us, 1000),
        reduction_percent: Float.round(100 * (1 - after_bytes / before_bytes), 2),
        all_revisions_verified: true,
        dispatch_preserved: true
      }
    after
      File.rm_rf!(dir)
    end
  end)

IO.puts(JSON.encode!(measurements))
