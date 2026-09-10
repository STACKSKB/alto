defmodule Alto.Command.Invocation do
  @moduledoc "A validated, resolved command ready for an execution backend."

  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  @default_output_bytes 64_000
  @max_output_bytes 1_000_000
  @max_args 128
  @max_argument_bytes 64_000

  @enforce_keys [:requested_program, :executable, :args, :cwd, :timeout_ms, :max_output_bytes]
  defstruct [:requested_program, :executable, :args, :cwd, :timeout_ms, :max_output_bytes]

  @type t :: %__MODULE__{
          requested_program: binary(),
          executable: binary(),
          args: [binary()],
          cwd: binary(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer()
        }

  def default_timeout_ms, do: @default_timeout_ms
  def max_timeout_ms, do: @max_timeout_ms
  def default_output_bytes, do: @default_output_bytes
  def max_output_bytes, do: @max_output_bytes
  def max_args, do: @max_args
  def max_argument_bytes, do: @max_argument_bytes
end
