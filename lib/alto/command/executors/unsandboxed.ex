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
  def execute(%Invocation{} = invocation) do
    started_ms = System.monotonic_time(:millisecond)

    case ExternalProcess.open(invocation.executable, invocation.args,
           cwd: invocation.cwd,
           timeout_ms: invocation.timeout_ms,
           stderr_to_stdout: true
         ) do
      {:ok, process} ->
        try do
          collect(
            ExternalProcess.port(process),
            started_ms,
            started_ms + invocation.timeout_ms,
            invocation.max_output_bytes,
            [],
            0
          )
        after
          ExternalProcess.close(process)
        end

      {:error, reason} ->
        {:error, {:command_start_failed, reason}}
    end
  end

  defp collect(port, started_ms, deadline_ms, limit, chunks, bytes) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        available = limit - bytes

        if byte_size(data) <= available do
          collect(port, started_ms, deadline_ms, limit, [data | chunks], bytes + byte_size(data))
        else
          kept = if available > 0, do: binary_part(data, 0, available), else: ""
          {:ok, result([kept | chunks], nil, started_ms, :output_limit)}
        end

      {^port, {:exit_status, status}} ->
        {:ok, result(chunks, status, started_ms, :exit)}
    after
      remaining_ms ->
        {:ok, result(chunks, nil, started_ms, :timeout)}
    end
  end

  defp result(chunks, exit_status, started_ms, termination) do
    output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    base = %{
      exit_status: exit_status,
      termination: termination,
      truncated: termination == :output_limit,
      timed_out: termination == :timeout,
      duration_ms: max(System.monotonic_time(:millisecond) - started_ms, 0)
    }

    if String.valid?(output) do
      Map.put(base, :output, output)
    else
      base
      |> Map.put(:output_base64, Base.encode64(output))
      |> Map.put(:encoding, "base64")
    end
  end
end
