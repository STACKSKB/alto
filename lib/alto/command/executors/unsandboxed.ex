defmodule Alto.Command.Executors.Unsandboxed do
  @moduledoc "Execute on the host with process-group cleanup but no security isolation."

  @behaviour Alto.Command.Executor

  alias Alto.Command.Invocation
  alias Alto.External.Process, as: ExternalProcess

  @impl true
  def prepare(%Invocation{} = invocation, _opts) do
    {:ok, invocation, %{backend: :unsandboxed, isolation: :none}}
  end

  @impl true
  def open(%Invocation{} = invocation, opts) do
    ExternalProcess.open(
      invocation.executable,
      invocation.args,
      Keyword.put(opts, :cwd, invocation.cwd)
    )
  end

  @impl true
  def execute(%Invocation{} = invocation) do
    started_ms = System.monotonic_time(:millisecond)

    case ExternalProcess.open(invocation.executable, invocation.args,
           cwd: invocation.cwd,
           startup_timeout: min(invocation.timeout_ms, 30_000),
           stderr_to_stdout: true
         ) do
      {:ok, process} ->
        try do
          collect(
            ExternalProcess.port(process),
            started_ms,
            started_ms + invocation.timeout_ms,
            invocation.max_output_bytes,
            %{head: <<>>, tail: <<>>, seen: 0, pending: <<>>}
          )
        after
          ExternalProcess.close(process)
        end

      {:error, reason} ->
        {:error, {:command_start_failed, reason}}
    end
  end

  defp collect(port, started_ms, deadline_ms, limit, capture) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      {:ok, result(capture, nil, started_ms, :timeout, limit)}
    else
      receive do
        {^port, {:data, data}} ->
          collect(port, started_ms, deadline_ms, limit, retain(capture, data, limit))

        {^port, {:exit_status, status}} ->
          {:ok, result(capture, status, started_ms, :exit, limit)}
      after
        remaining_ms -> {:ok, result(capture, nil, started_ms, :timeout, limit)}
      end
    end
  end

  defp retain(capture, data, limit) do
    seen = capture.seen + byte_size(data)

    head =
      if byte_size(capture.head) < limit do
        take = min(limit - byte_size(capture.head), byte_size(data))
        capture.head <> binary_part(data, 0, take)
      else
        capture.head
      end

    tail = keep_tail(capture.tail, data, limit)
    %{capture | head: head, tail: tail, seen: seen, pending: update_utf8(capture.pending, data)}
  end

  defp update_utf8(:invalid, _data), do: :invalid

  defp update_utf8(pending, data) do
    case :unicode.characters_to_binary(pending <> data) do
      binary when is_binary(binary) -> <<>>
      {:incomplete, _valid, rest} -> rest
      {:error, _valid, _rest} -> :invalid
    end
  end

  defp keep_tail(_old, _data, 0), do: <<>>

  defp keep_tail(old, data, limit) do
    combined = old <> data

    if byte_size(combined) <= limit,
      do: combined,
      else: :binary.copy(binary_part(combined, byte_size(combined) - limit, limit))
  end

  defp result(capture, exit_status, started_ms, termination, limit) do
    truncated? = capture.seen > limit
    output = captured_output(capture, limit, truncated?)

    base = %{
      exit_status: exit_status,
      termination: termination,
      truncated: truncated?,
      timed_out: termination == :timeout,
      duration_ms: max(System.monotonic_time(:millisecond) - started_ms, 0)
    }

    if capture.pending != :invalid and String.valid?(output) do
      Map.put(base, :output, output)
    else
      base
      |> Map.put(:output_base64, Base.encode64(output))
      |> Map.put(:encoding, "base64")
    end
  end

  defp captured_output(_capture, 0, _truncated), do: <<>>
  defp captured_output(capture, _limit, false), do: capture.head

  defp captured_output(capture, limit, true) do
    marker =
      if byte_size("\n… output truncated …\n") < limit, do: "\n… output truncated …\n", else: ""

    available = max(limit - byte_size(marker), 0)
    # Tiny caps cannot fit an elision marker; preserve the diagnostic tail.
    tail_limit = if marker == "", do: available, else: div(available + 1, 2)
    head_limit = available - tail_limit
    head = binary_part(capture.head, 0, min(byte_size(capture.head), head_limit))

    tail =
      if tail_limit == 0,
        do: <<>>,
        else:
          binary_part(
            capture.tail,
            max(byte_size(capture.tail) - tail_limit, 0),
            min(byte_size(capture.tail), tail_limit)
          )

    if capture.pending == :invalid,
      do: head <> marker <> tail,
      else: Alto.Text.prefix(head, byte_size(head)) <> marker <> repair_tail(tail)
  end

  defp repair_tail(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: repair_tail(rest)

  defp repair_tail(fragment),
    do: Alto.Text.prefix(fragment, byte_size(fragment))
end
