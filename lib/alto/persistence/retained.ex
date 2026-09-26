defmodule Alto.Persistence.Retained do
  @moduledoc """
  Generation-bound retained cells in an Alto.OperationLog.

  Domains validate initial data and packets and decide mutation/retirement
  eligibility. Cells own the storage envelope, deadlines, generation/revision
  fences, CAS retries and durable lifecycle completion.
  """

  alias Alto.OperationLog

  @enforce_keys [:ledger, :key, :kind, :generation]
  defstruct [:ledger, :key, :kind, :generation, deadline: :infinity]
  @type t :: %__MODULE__{}
  @initialize "initialize-retained-cell"
  @retire "retire-retained-cell"
  @default_call_timeout 5_000

  @doc "Validate options for a retained-record lookup and return its deadline."
  def deadline([]), do: {:ok, :infinity}

  def deadline(deadline: deadline),
    do: with(:ok <- deadline_ok(deadline), do: {:ok, deadline})

  def deadline(_), do: {:error, :invalid_retained_options}

  def deadline_ok(:infinity), do: :ok

  def deadline_ok(deadline) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :run_timeout}
  end

  def deadline_ok(_), do: {:error, :invalid_deadline}

  def call_timeout(:infinity), do: @default_call_timeout

  def call_timeout(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  def call_timeout(_), do: 0

  @doc "Execute a native ledger request under the supplied absolute monotonic deadline."
  @spec request(GenServer.server(), OperationLog.request(), integer() | :infinity) :: term()
  def request(ledger, message, deadline \\ :infinity) do
    with :ok <- deadline_ok(deadline),
         do: OperationLog.request(ledger, message, call_timeout(deadline))
  catch
    :exit, {:timeout, _} -> {:error, :run_timeout}
    :exit, reason -> {:error, {:retained_unavailable, reason}}
  end

  @doc "Create or reconnect a generation-bound retained cell."
  def open(ledger, key, kind, initial, packet, deadline \\ :infinity) do
    recovery = %{"version" => 1, "generation" => nonce(), "initial" => initial}

    with :ok <-
           request(
             ledger,
             {:retain, key, Atom.to_string(kind), recovery, @initialize, packet},
             deadline
           ),
         do: lookup(ledger, key, kind, deadline: deadline)
  end

  def lookup(ledger, key, kind, opts \\ []) do
    with {:ok, deadline} <- deadline(opts),
         {:ok, entry} <- request(ledger, {:recovery, key}, deadline),
         {:ok, snapshot} <- snapshot(entry, kind) do
      {:ok,
       %__MODULE__{
         ledger: ledger,
         key: key,
         kind: kind,
         generation: entry.recovery["generation"],
         deadline: deadline
       }, snapshot}
    end
  end

  def identity(%__MODULE__{key: key, generation: generation}),
    do: %{"key" => key, "generation" => generation}

  def restore(ledger, identity, kind, opts \\ [])

  def restore(ledger, %{"key" => key, "generation" => generation} = identity, kind, opts)
      when map_size(identity) == 2 and is_binary(key) and is_binary(generation) do
    with {:ok, cell, _} <- lookup(ledger, key, kind, opts),
         true <- cell.generation == generation do
      {:ok, cell}
    else
      false -> {:error, :retained_generation_mismatch}
      {:error, _} = error -> error
    end
  end

  def restore(_, _, _, _), do: {:error, :invalid_retained_identity}

  def read(%__MODULE__{} = cell) do
    with {:ok, entry} <- request(cell.ledger, {:recovery, cell.key}, cell.deadline),
         {:ok, current} <- snapshot(entry, cell.kind),
         true <- entry.recovery["generation"] == cell.generation do
      {:ok, current}
    else
      false -> {:error, :retained_generation_mismatch}
      {:error, _} = error -> error
    end
  end

  def snapshot(
        %{
          tool: tool,
          recovery:
            %{"version" => 1, "generation" => generation, "initial" => initial} = recovery,
          checkpoint: packet,
          revision: revision
        } = entry,
        kind
      )
      when map_size(recovery) == 3 and is_binary(generation) and byte_size(generation) == 32 and
             is_map(initial) and is_integer(revision) and revision >= 1 do
    with true <- tool == Atom.to_string(kind),
         true <- String.match?(generation, ~r/\A[0-9a-f]+\z/),
         {:ok, state} <- lifecycle(entry, generation) do
      # The kind is an internal domain module, not a model-selected callback.
      kind.snapshot(%{revision: revision, packet: packet, initial: initial, state: state})
    else
      false -> {:error, :invalid_retained_cell}
      {:error, _} = error -> error
    end
  end

  def snapshot(_, _), do: {:error, :invalid_retained_cell}

  def replace(%__MODULE__{} = cell, snapshot, packet) do
    with true <- snapshot.state == :active,
         {:ok, entry} <-
           request(
             cell.ledger,
             {:checkpoint_update, cell.key, {snapshot.revision, cell.generation}, packet},
             cell.deadline
           ),
         {:ok, current} <- snapshot(entry, cell.kind),
         true <- entry.recovery["generation"] == cell.generation do
      {:ok, current}
    else
      false -> {:error, :retained_closed}
      {:error, _} = error -> error
    end
  end

  def update(%__MODULE__{} = cell, fun) do
    with {:ok, current} <- read(cell),
         true <- current.state == :active,
         {:ok, packet} <- fun.(current) do
      if packet == current.packet do
        {:ok, current}
      else
        case replace(cell, current, packet) do
          {:error, :stale_revision} -> update(cell, fun)
          result -> result
        end
      end
    else
      false -> {:error, :retained_closed}
      {:error, _} = error -> error
    end
  end

  def retire(%__MODULE__{} = cell, expected_revision) do
    with {:ok, current} <- read(cell), true <- current.revision == expected_revision do
      if current.state == :retired,
        do: :ok,
        else:
          request(
            cell.ledger,
            {:retire_checkpoint, cell.key, {expected_revision, cell.generation},
             %{"action" => @retire, "generation" => cell.generation}, @retire,
             %{"generation" => cell.generation}},
            cell.deadline
          )
    else
      false -> {:error, :stale_revision}
      {:error, _} = error -> error
    end
  end

  defp lifecycle(%{status: {:checkpointed, _, @initialize}}, _), do: {:ok, :active}

  defp lifecycle(
         %{
           checkpoint_decision: %{"action" => @retire, "generation" => generation},
           status: {:decided, :completed, %{"generation" => generation}}
         },
         generation
       ),
       do: {:ok, :retired}

  defp lifecycle(_, _), do: {:error, :invalid_retained_cell}

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
